import Foundation
import os

/// Result of a single `git` invocation.
struct GitCommandResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool

    var succeeded: Bool { !timedOut && exitCode == 0 }
    /// Prefer stderr (git writes progress/errors there); fall back to stdout.
    var message: String {
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : e
    }
}

/// Seam so tests can assert the exact command sequence without spawning git.
protocol GitCommandRunning: Sendable {
    func run(_ arguments: [String], in directory: URL) async -> GitCommandResult
}

/// Commits + rebases + pushes an Obsidian vault git repo after a note is
/// written. Modelled on the confirmed flow:
///
///   1. `git add <file>`
///   2. `git commit -m <msg>`   (skipped cleanly when nothing changed)
///   3. `git pull --rebase origin <branch>`
///   4. `git push origin HEAD:<branch>`
///
/// On a rebase conflict we `git rebase --abort` so the vault is never left
/// mid-conflict — the local commit is preserved and pushes on the next
/// successful sync. All steps are non-interactive (see `ProcessGitCommandRunner`)
/// and the whole thing is an `actor`, so concurrent recording completions can't
/// interleave git commands in the same repo.
actor ObsidianGitSyncer {
    private let runner: GitCommandRunning

    init(runner: GitCommandRunning = ProcessGitCommandRunner()) {
        self.runner = runner
    }

    /// Run the sync. Returns nil on success, or a human-readable error string
    /// to surface in Settings (the caller stores it on
    /// `ObsidianVaultSettings.lastSyncError`).
    ///
    /// `changedPaths` are staged with `git add --all --` so note additions,
    /// modifications, AND deletions (from a rename/overwrite) are all captured
    /// while leaving the user's unrelated vault files untouched.
    @discardableResult
    func sync(vault: URL,
              changedPaths: [URL],
              branch: String,
              commitMessage: String) async -> String? {
        // Locate the repo toplevel from the vault dir. Doubles as the
        // "is this a git repo?" guard.
        let top = await runner.run(["rev-parse", "--show-toplevel"], in: vault)
        guard top.succeeded else {
            return "The Obsidian vault is not a git repository (git rev-parse failed)."
        }
        let toplevelPath = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let toplevel = toplevelPath.isEmpty ? vault : URL(fileURLWithPath: toplevelPath)

        let add = await runner.run(["add", "--all", "--"] + changedPaths.map(\.path), in: toplevel)
        guard add.succeeded else { return "git add failed: \(add.message)" }

        let commit = await runner.run(["commit", "-m", commitMessage], in: toplevel)
        if !commit.succeeded {
            // A re-export of unchanged content leaves nothing to commit —
            // that's fine, we still want to pull/push. Anything else is a
            // real failure.
            let lower = commit.message.lowercased()
            let nothingToCommit = lower.contains("nothing to commit")
                || lower.contains("no changes added")
                || lower.contains("working tree clean")
            if !nothingToCommit { return "git commit failed: \(commit.message)" }
        }

        let pull = await runner.run(["pull", "--rebase", "origin", branch], in: toplevel)
        guard pull.succeeded else {
            // Never leave the vault mid-rebase.
            _ = await runner.run(["rebase", "--abort"], in: toplevel)
            return "git pull --rebase failed (aborted): \(pull.message)"
        }

        let push = await runner.run(["push", "origin", "HEAD:\(branch)"], in: toplevel)
        guard push.succeeded else { return "git push failed: \(push.message)" }

        return nil
    }
}

/// Production `GitCommandRunning` — spawns the real `git` binary with a bounded
/// timeout and a non-interactive environment (no credential/host prompts that
/// would hang a background sync).
struct ProcessGitCommandRunner: GitCommandRunning {
    var timeout: TimeInterval = 120

    func run(_ arguments: [String], in directory: URL) async -> GitCommandResult {
        let timeout = self.timeout
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.runSync(arguments, in: directory, timeout: timeout))
            }
        }
    }

    /// Resolve `git`: prefer the system binary shipped with the Command Line
    /// Tools, then fall back to the same version-manager dirs `LLMRunner`
    /// searches (a Finder-launched app has a stripped PATH).
    static func gitExecutable() -> URL? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: "/usr/bin/git") {
            return URL(fileURLWithPath: "/usr/bin/git")
        }
        for dir in LLMRunner.searchDirectories() {
            let candidate = (dir as NSString).appendingPathComponent("git")
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private static func runSync(_ arguments: [String],
                                in directory: URL,
                                timeout: TimeInterval) -> GitCommandResult {
        guard let git = gitExecutable() else {
            return GitCommandResult(exitCode: -1, stdout: "",
                                    stderr: "git executable not found on PATH", timedOut: false)
        }
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.currentDirectoryURL = directory

        // Augment PATH so git finds any helpers, then force non-interactive:
        //  * GIT_TERMINAL_PROMPT=0 — never prompt for username/password.
        //  * GIT_SSH_COMMAND BatchMode — SSH fails fast instead of prompting
        //    for a passphrase / unknown-host confirmation.
        // A missing credential thus errors quickly rather than hanging the
        // background sync forever.
        var env = LLMRunner.childEnvironment(for: git)
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return GitCommandResult(exitCode: -1, stdout: "",
                                    stderr: "failed to launch git: \(error.localizedDescription)",
                                    timedOut: false)
        }
        try? stdinPipe.fileHandleForWriting.close()

        // Drain both pipes on background threads so a chatty git can't
        // deadlock by filling the OS pipe buffer while we wait for exit.
        let outBox = OSAllocatedUnfairLock(initialState: Data())
        let errBox = OSAllocatedUnfairLock(initialState: Data())
        let drain = DispatchGroup()
        for (pipe, box) in [(stdoutPipe, outBox), (stderrPipe, errBox)] {
            drain.enter()
            DispatchQueue.global().async {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    box.withLock { $0.append(chunk) }
                }
                drain.leave()
            }
        }

        let running = DispatchGroup()
        running.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            running.leave()
        }
        let deadline = DispatchTime.now() + .seconds(Int(timeout.rounded(.up)))
        let timedOut = running.wait(timeout: deadline) == .timedOut
        if timedOut {
            process.terminate()
            if running.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = running.wait(timeout: .now() + 3)
            }
        }
        _ = drain.wait(timeout: .now() + 5)

        let stdout = String(data: outBox.withLock { $0 }, encoding: .utf8) ?? ""
        let stderr = String(data: errBox.withLock { $0 }, encoding: .utf8) ?? ""
        return GitCommandResult(exitCode: timedOut ? -1 : process.terminationStatus,
                                stdout: stdout,
                                stderr: stderr,
                                timedOut: timedOut)
    }
}
