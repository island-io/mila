import XCTest
@testable import Mila

/// End-to-end git tests that run the REAL `git` binary (via the production
/// `ProcessGitCommandRunner`) against a temporary working copy wired to a local
/// bare "remote". Proves the actual add -> commit -> pull --rebase -> push flow
/// lands commits on the remote, and that a non-conflicting remote change is
/// rebased in rather than rejected. Skips cleanly when `git` isn't installed.
final class ObsidianGitSyncerIntegrationTests: XCTestCase {

    private var gitURL: URL!
    private var tempRoot: URL!
    private var home: URL!
    private var remote: URL!
    private var vault: URL!
    /// Original values of the git-config env vars we override on THIS process,
    /// so `tearDown` can put them back. `nil` value == the var was unset.
    private var savedEnvironment: [String: String?] = [:]

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let git = ProcessGitCommandRunner.gitExecutable() else {
            throw XCTSkip("git is not installed on this machine")
        }
        gitURL = git
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaGitIntegration-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        // Isolated HOME so setup commands don't read the developer's global
        // git config (default branch name, gpg signing, hooks).
        home = tempRoot.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        // `runGit` can isolate its own child env, but the code under test runs
        // through `ProcessGitCommandRunner`, which inherits this process's
        // environment verbatim. Without overriding these here, the sync steps
        // would read the developer's / CI machine's real global + system git
        // config (default branch, gpg signing, hooks, insteadOf rewrites).
        // `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` need git >= 2.32; the older
        // `GIT_CONFIG_NOSYSTEM` is set too so isolation still holds below that.
        let globalConfig = home.appendingPathComponent(".gitconfig")
        FileManager.default.createFile(atPath: globalConfig.path, contents: nil)
        setEnvironment([
            "GIT_CONFIG_GLOBAL": globalConfig.path,
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1"
        ])

        remote = tempRoot.appendingPathComponent("remote.git", isDirectory: true)
        vault = tempRoot.appendingPathComponent("vault", isDirectory: true)

        // Bare remote whose default branch is `main`.
        try runGit(["init", "--bare", remote.path], in: tempRoot)
        try runGit(["symbolic-ref", "HEAD", "refs/heads/main"], in: remote)

        // Working copy on `main` with identity + no gpg signing, an initial
        // commit, and `origin` pointing at the bare remote.
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try runGit(["init", vault.path], in: tempRoot)
        try configureRepo(vault)
        try runGit(["checkout", "-b", "main"], in: vault)
        try write("# vault\n", to: vault.appendingPathComponent("README.md"))
        try runGit(["add", "."], in: vault)
        try runGit(["commit", "-m", "init"], in: vault)
        try runGit(["remote", "add", "origin", remote.path], in: vault)
        try runGit(["push", "-u", "origin", "main"], in: vault)
    }

    override func tearDownWithError() throws {
        restoreEnvironment()
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try super.tearDownWithError()
    }

    /// Override env vars on this process, remembering the previous values.
    private func setEnvironment(_ values: [String: String]) {
        for (key, value) in values {
            if !savedEnvironment.keys.contains(key) {
                savedEnvironment[key] = ProcessInfo.processInfo.environment[key]
            }
            setenv(key, value, 1)
        }
    }

    private func restoreEnvironment() {
        for (key, value) in savedEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        savedEnvironment.removeAll()
    }

    // MARK: - Tests

    func test_sync_commits_and_pushes_note_to_remote() async throws {
        let note = vault.appendingPathComponent("2026-01-02 Meeting.md")
        try write("# Meeting\n\nSummary body.\n", to: note)

        let syncer = ObsidianGitSyncer()   // real ProcessGitCommandRunner
        let error = await syncer.sync(vault: vault,
                                      changedPaths: [note],
                                      branch: "main",
                                      commitMessage: "Add transcript: Meeting")
        XCTAssertNil(error, "expected a clean sync, got: \(error ?? "")")

        // The remote now carries the commit and the file's content.
        let log = try runGit(["log", "--oneline"], in: remote)
        XCTAssertTrue(log.contains("Add transcript: Meeting"),
                      "remote log should contain the note commit; got:\n\(log)")
        let show = try runGit(["show", "main:2026-01-02 Meeting.md"], in: remote)
        XCTAssertTrue(show.contains("Summary body."),
                      "remote should hold the pushed note content")
    }

    func test_sync_rebases_nonconflicting_remote_change_and_pushes() async throws {
        // A second checkout pushes an unrelated file, so the remote `main` is
        // now ahead of the vault.
        let other = tempRoot.appendingPathComponent("other", isDirectory: true)
        try runGit(["clone", remote.path, other.path], in: tempRoot)
        try configureRepo(other)
        try write("remote-added\n", to: other.appendingPathComponent("b.md"))
        try runGit(["add", "."], in: other)
        try runGit(["commit", "-m", "remote change b"], in: other)
        try runGit(["push", "origin", "HEAD:main"], in: other)

        // The vault writes its own note and syncs; pull --rebase must fold in
        // the remote's commit, then push both.
        let note = vault.appendingPathComponent("a.md")
        try write("local-added\n", to: note)
        let syncer = ObsidianGitSyncer()
        let error = await syncer.sync(vault: vault,
                                      changedPaths: [note],
                                      branch: "main",
                                      commitMessage: "Add transcript: A")
        XCTAssertNil(error, "expected a clean rebase+push, got: \(error ?? "")")

        let files = try runGit(["ls-tree", "--name-only", "main"], in: remote)
        XCTAssertTrue(files.contains("a.md"), "the vault's note must be pushed; got:\n\(files)")
        XCTAssertTrue(files.contains("b.md"), "the remote's commit must be preserved; got:\n\(files)")
    }

    // MARK: - Helpers

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = gitURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = home.path
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = env

        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        // Drain BOTH pipes before waiting for exit. A macOS pipe buffer is
        // ~64 KB; git writes progress and diagnostics to stderr, so waiting
        // first lets git block on `write()` while we block on `waitUntilExit()`
        // — the deadlock `.claude/rules/python-subprocess.md` documents (it
        // hung transcription on long files once already, PR #15).
        //
        // `DispatchGroup` rather than `Task.detached` here because this helper
        // is synchronous: the rule prefers `Task.detached` specifically to
        // avoid blocking a cooperative thread from an *async* context, which
        // this is not.
        let lock = NSLock()
        var outData = Data(), errData = Data()
        let drain = DispatchGroup()
        for (pipe, isStdout) in [(out, true), (err, false)] {
            drain.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isStdout { outData = data } else { errData = data }
                lock.unlock()
                drain.leave()
            }
        }
        process.waitUntilExit()
        drain.wait()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(stderr)\(stdout)"
            ])
        }
        return stdout
    }

    private func configureRepo(_ repo: URL) throws {
        try runGit(["config", "user.email", "test@example.com"], in: repo)
        try runGit(["config", "user.name", "Mila Test"], in: repo)
        try runGit(["config", "commit.gpgsign", "false"], in: repo)
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
