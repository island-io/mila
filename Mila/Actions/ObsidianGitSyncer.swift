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

    /// `obsidian.git.branch` is a free-text Settings field, and it lands in an
    /// argument position where git would happily read it as an option: a branch
    /// named `--upload-pack=/bin/sh` turns `git pull --rebase origin <branch>`
    /// into a remote-helper override. Reject anything git itself would refuse
    /// as a ref name, and anything that could be parsed as a flag or a revision
    /// operator, before a single command runs.
    ///
    /// Roughly `git check-ref-format --branch`, minus the exotic rules — this
    /// is a guard, not a reimplementation.
    static func isValidBranch(_ branch: String) -> Bool {
        guard !branch.isEmpty, branch.utf8.count <= 255 else { return false }
        // The one that actually matters: never parsable as an option.
        guard !branch.hasPrefix("-") else { return false }
        guard !branch.hasPrefix("/"), !branch.hasSuffix("/") else { return false }
        guard !branch.hasPrefix("."), !branch.hasSuffix(".") else { return false }
        guard !branch.contains(".."), !branch.contains("@{") else { return false }
        guard !branch.hasSuffix(".lock") else { return false }
        let forbidden = CharacterSet(charactersIn: " \t~^:?*[]\\\u{7F}")
            .union(.controlCharacters)
            .union(.newlines)
        return branch.rangeOfCharacter(from: forbidden) == nil
    }

    /// Fully-qualified form of `branch`. Belt and braces alongside
    /// `isValidBranch`: a `refs/heads/`-prefixed argument can never begin with
    /// `-`, so it cannot reach git in an option position however the validation
    /// above evolves. It also removes the tag/branch ambiguity of a bare name.
    private static func ref(_ branch: String) -> String { "refs/heads/\(branch)" }

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
        // Validate before anything is spawned: a hostile branch value must not
        // reach a git argument list at all.
        guard Self.isValidBranch(branch) else {
            return "\"\(branch)\" is not a valid git branch name. "
                + "Change it in Settings ▸ Storage."
        }

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

        let pull = await runner.run(["pull", "--rebase", "origin", Self.ref(branch)], in: toplevel)
        guard pull.succeeded else {
            // Never leave the vault mid-rebase.
            _ = await runner.run(["rebase", "--abort"], in: toplevel)
            return "git pull --rebase failed (aborted): \(pull.message)"
        }

        let push = await runner.run(["push", "origin", "HEAD:\(Self.ref(branch))"], in: toplevel)
        guard push.succeeded else { return "git push failed: \(push.message)" }

        return nil
    }
}

/// Production `GitCommandRunning` — spawns the real `git` binary with a bounded
/// timeout and a non-interactive environment (no credential/host prompts that
/// would hang a background sync).
struct ProcessGitCommandRunner: GitCommandRunning {
    var timeout: TimeInterval = 120

    /// Extra environment applied to the child `git` only, after the defaults
    /// below and before `run()`. Empty in production.
    ///
    /// It exists so a test can isolate git's config discovery
    /// (`GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, `HOME`) **per invocation**
    /// instead of via `setenv` on the test host (issue #246). The host is a
    /// live SwiftUI app: `setenv` can `realloc` `environ` underneath a
    /// concurrent `getenv`/`posix_spawn` on another thread, which is a real
    /// data race and not one the suite doing it can contain.
    var environment: [String: String] = [:]

    func run(_ arguments: [String], in directory: URL) async -> GitCommandResult {
        let timeout = self.timeout
        let environment = self.environment
        return await withCheckedContinuation { continuation in
            // A thread of its own, not `DispatchQueue.global()`: `runSync`
            // blocks for the whole life of the child, and a pooled thread
            // parked there starves whatever is queued behind it (issue #246,
            // see `BlockingWork`).
            BlockingWork.onDedicatedThread(named: "io.island.mila.git.run") {
                continuation.resume(returning: Self.runSync(arguments,
                                                            in: directory,
                                                            timeout: timeout,
                                                            environment: environment))
            }
        }
    }

    /// Resolve `git`: prefer the system binary shipped with the Command Line
    /// Tools, then fall back to well-known shell-managed `bin` dirs. A
    /// Finder-launched app inherits a stripped PATH from launchd, so a
    /// Homebrew git is typically absent from it.
    static func gitExecutable() -> URL? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: "/usr/bin/git") {
            return URL(fileURLWithPath: "/usr/bin/git")
        }
        for dir in searchDirectories() {
            let candidate = (dir as NSString).appendingPathComponent("git")
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Inherited `$PATH` first, then the usual shell-managed locations.
    static func searchDirectories(home: String = NSHomeDirectory(),
                                  pathEnv: String? = ProcessInfo.processInfo.environment["PATH"]) -> [String] {
        var dirs: [String] = []
        if let pathEnv {
            dirs += pathEnv.split(separator: ":").map(String.init)
        }
        dirs += [
            "\(home)/.local/bin",
            "\(home)/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func runSync(_ arguments: [String],
                                in directory: URL,
                                timeout: TimeInterval,
                                environment: [String: String]) -> GitCommandResult {
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
        var env = ProcessInfo.processInfo.environment
        // git shells out to its own helpers (git-remote-https, credential
        // helpers), which live beside the binary — put that directory first
        // so a non-system git finds them under launchd's stripped PATH.
        env["PATH"] = ([git.deletingLastPathComponent().path] + Self.searchDirectories())
            .joined(separator: ":")
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
        // `sync` classifies a failed commit by substring-matching git's human
        // output ("nothing to commit"). git translates those messages under a
        // non-English locale, which would turn a clean no-op re-export into a
        // reported sync failure — so pin the locale instead of inheriting the
        // user's. Commit messages are unaffected: git stores the argv bytes
        // as-is under `i18n.commitEncoding` (UTF-8).
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        env.removeValue(forKey: "LANGUAGE")
        // Caller overrides last, so a test can pin git's config discovery for
        // this child without touching the host process's `environ`.
        for (key, value) in environment { env[key] = value }
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Exit notification with no blocking wait on the shared pool — same
        // change, same reason, as `LLMRunner.executeProcess` (issue #246).
        // Must be installed before `run()`. The `waitUntilExit()` backstop
        // below covers the macOS 26 reaping race the runner documents.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

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
            // Dedicated threads, not the global pool: `availableData` blocks
            // until EOF (issue #246, see `BlockingWork`).
            let stream = pipe === stdoutPipe ? "stdout" : "stderr"
            BlockingWork.onDedicatedThread(named: "io.island.mila.git.drain.\(stream)") {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    box.withLock { $0.append(chunk) }
                }
                drain.leave()
            }
        }

        BlockingWork.onDedicatedThread(named: "io.island.mila.git.reap") {
            process.waitUntilExit()
            exited.signal()
        }
        let deadline = DispatchTime.now() + .seconds(Int(timeout.rounded(.up)))
        let timedOut = exited.wait(timeout: deadline) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 3)
            }
        }
        // 5s used to be a coin toss: the readers were queued on the
        // non-overcommit global pool, where simply BEING SCHEDULED could take
        // 10-15s on a loaded runner, and an expired drain here silently
        // returns short output. They now run on threads of their own and hit
        // EOF as soon as git's write ends close, so this bounds a genuinely
        // stuck reader (a helper git spawned still holding the pipes) rather
        // than dispatch latency — but keep the headroom anyway, because the
        // cost of expiring early is a wrong answer, not a slow one.
        _ = drain.wait(timeout: .now() + 15)

        let stdout = String(data: outBox.withLock { $0 }, encoding: .utf8) ?? ""
        let stderr = String(data: errBox.withLock { $0 }, encoding: .utf8) ?? ""
        return GitCommandResult(exitCode: timedOut ? -1 : process.terminationStatus,
                                stdout: stdout,
                                stderr: stderr,
                                timedOut: timedOut)
    }
}
