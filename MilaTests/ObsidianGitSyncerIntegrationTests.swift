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

    /// Temp roots this class has created so far in this process.
    ///
    /// `setUp` asserts every EARLIER one is gone (issue #246). Checking in
    /// `setUp` rather than `tearDown` is the point: a root is named after the
    /// test that created it, so the failure says which test leaked rather than
    /// landing on whichever test happened to run next. The ledger is drained
    /// as it is checked, so one leak reports once instead of reddening every
    /// remaining test in the class.
    ///
    /// Not concurrency-guarded because XCTest runs a class's tests serially on
    /// one thread; `setUp` is the only reader and writer.
    private static var previousRoots: [URL] = []

    /// Per-`git`-invocation bound, for BOTH the setup helper below and the
    /// production runner the tests drive (issue #208).
    ///
    /// Nothing here is slow: every command runs against a three-object local
    /// repo and finishes in milliseconds, so 60s is ~4 orders of magnitude of
    /// headroom and cannot fail a loaded runner. What it buys is the
    /// difference between the two ways a wedged `git` can end.
    ///
    /// CI gives each test 240s (`-default-test-execution-time-allowance`, see
    /// `.github/workflows/ios-tests.yml`). An unbounded wait therefore cannot
    /// fail *as a test*: XCTest kills the whole test HOST first, which records
    /// no assertion message and cannot be recovered by
    /// `-retry-tests-on-failure`, so the job prints a bare `Failing tests: …`
    /// line with no cause anywhere in the log. A bounded wait fails normally,
    /// says which command hung, and gets retried.
    ///
    /// This is not hypothetical for `Process`. `LLMRunner.executeProcess`
    /// documents a macOS 26 reaping race where `waitUntilExit` never returns
    /// even after `SIGKILL`, and `readDataToEndOfFile` never returns while any
    /// process — including a helper `git` spawned that outlived it — still
    /// holds the write end of the pipe. `ProcessGitCommandRunner.runSync`
    /// bounds both for exactly these reasons; this helper did not, and it is
    /// the last unbounded subprocess wait in the bundle.
    private static let gitCommandTimeout: TimeInterval = 60

    /// How long to wait for the output pipes to reach EOF once `git` has
    /// exited. Separate from `gitCommandTimeout` because it bounds a different
    /// hazard: not a wedged `git`, but a reader that has not finished.
    ///
    /// It used to bound a reader that had not been SCHEDULED — the readers sat
    /// on the non-overcommit global queue, where 10-15s of dispatch latency is
    /// documented for this CI image, and a 5s bound cost this suite a
    /// deterministic failure. They now run on threads of their own (issue
    /// #246), so scheduling is immediate and this bounds only a reader still
    /// blocked on a pipe some helper `git` spawned is holding open. Kept
    /// generous anyway: expiring early returns a WRONG answer, not a slow one.
    private static let pipeDrainTimeout: TimeInterval = 30

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard let git = ProcessGitCommandRunner.gitExecutable() else {
            throw XCTSkip("git is not installed on this machine")
        }
        gitURL = git

        // Cleanliness is asserted HERE, before this test creates anything, so
        // a leaked root is reported against the test named in its own path
        // (issue #246). Drain the ledger while checking it: the leak is a fact
        // about the run that caused it, not about every test after it.
        let stale = Self.previousRoots.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        Self.previousRoots.removeAll()
        for root in stale {
            XCTFail("a previous test in this class left its temp root behind — "
                    + "the directory name says which one: \(root.lastPathComponent)")
            try? FileManager.default.removeItem(at: root)
        }

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaGitIntegration-\(testLabel)-\(UUID())",
                                    isDirectory: true)
        Self.previousRoots.append(tempRoot)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        // Isolated HOME so setup commands don't read the developer's global
        // git config (default branch name, gpg signing, hooks).
        home = tempRoot.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        // The empty global config `gitIsolation` points at. Both `runGit` and
        // the production runner receive that pointer as CHILD environment (see
        // `gitIsolation`) — this process's own `environ` is never touched.
        FileManager.default.createFile(atPath: home.appendingPathComponent(".gitconfig").path,
                                       contents: nil)

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
        // Report a removal that FAILED, rather than swallowing it with `try?`.
        // The ledger in `setUp` is the cross-test net, but it is only read by
        // the NEXT test — so without this the last test in the class could leak
        // and nothing would ever say so. `tearDown` still runs in the failing
        // test's own context, so the attribution is right either way.
        if let tempRoot, FileManager.default.fileExists(atPath: tempRoot.path) {
            do {
                try FileManager.default.removeItem(at: tempRoot)
                Self.previousRoots.removeAll { $0 == tempRoot }
            } catch {
                XCTFail("could not remove this test's temp root "
                        + "\(tempRoot.lastPathComponent): \(error.localizedDescription)")
            }
        } else if let tempRoot {
            Self.previousRoots.removeAll { $0 == tempRoot }
        }
        try super.tearDownWithError()
    }

    /// `name` is `-[ObsidianGitSyncerIntegrationTests test_foo]`; keep the
    /// `test_foo` so a leaked temp root names the test that leaked it.
    private var testLabel: String {
        let raw = name.split(separator: " ").last.map(String.init) ?? name
        return String(raw.filter { $0.isLetter || $0.isNumber || $0 == "_" })
    }

    /// Git-config isolation, as CHILD environment rather than as a mutation of
    /// this process (issue #246).
    ///
    /// This used to be `setenv`/`unsetenv` in `setUp`/`tearDown`, because the
    /// code under test runs through `ProcessGitCommandRunner`, which inherits
    /// the host's environment verbatim and had no other way in. The test host
    /// is a live SwiftUI app: `setenv` can `realloc` `environ` underneath a
    /// concurrent `getenv` or `posix_spawn` on another thread, so a suite
    /// reaching for it is a process-wide data race that no amount of care
    /// inside this class can contain. `ProcessGitCommandRunner` now takes
    /// per-invocation `environment`, so nothing here escapes the child.
    ///
    /// `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` need git >= 2.32; the older
    /// `GIT_CONFIG_NOSYSTEM` is set too so isolation still holds below that.
    /// Without them the sync steps would read the developer's / CI machine's
    /// real global + system git config (default branch, gpg signing, hooks,
    /// insteadOf rewrites).
    private var gitIsolation: [String: String] {
        [
            "HOME": home.path,
            "GIT_CONFIG_GLOBAL": home.appendingPathComponent(".gitconfig").path,
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0"
        ]
    }

    // MARK: - Tests

    func test_sync_commits_and_pushes_note_to_remote() async throws {
        let note = vault.appendingPathComponent("2026-01-02 Meeting.md")
        try write("# Meeting\n\nSummary body.\n", to: note)

        let syncer = ObsidianGitSyncer(runner: boundedRunner())
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
        let syncer = ObsidianGitSyncer(runner: boundedRunner())
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

    /// The REAL production runner — still `ProcessGitCommandRunner`, so these
    /// stay integration tests — with its per-command bound brought inside the
    /// per-test allowance (issue #208).
    ///
    /// Its shipped 120s is right for a background sync over the network and
    /// wrong here: `sync` issues up to six commands, so 6 × (120s + kill
    /// grace) is ~780s against a 240s allowance. One wedged command would take
    /// the test host with it instead of failing the test. 20s is still ~4
    /// orders of magnitude above what a local-path git command costs.
    private func boundedRunner() -> ProcessGitCommandRunner {
        var runner = ProcessGitCommandRunner()
        runner.timeout = 20
        runner.environment = gitIsolation
        return runner
    }

    @discardableResult
    private func runGit(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = gitURL
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        for (key, value) in gitIsolation { env[key] = value }
        process.environment = env

        // Exit notification that costs no thread at all, installed before
        // `run()` — mirrors `ProcessGitCommandRunner.runSync` (issue #246).
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

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
        //
        // The readers run on threads of their OWN rather than on
        // `DispatchQueue.global()` (issue #246). `availableData` blocks until
        // EOF, and the global queues are non-overcommit: a pooled thread
        // parked in a blocking read is one the whole process loses, and the
        // items queued behind it then wait to be *scheduled* — which is what
        // the dispatch latency `pipeDrainTimeout` describes actually was.
        let lock = NSLock()
        var outData = Data(), errData = Data()
        let drain = DispatchGroup()
        for (pipe, isStdout) in [(out, true), (err, false)] {
            drain.enter()
            BlockingWork.onDedicatedThread(named: "mila.test.git.drain") {
                // Append chunk-by-chunk rather than one `readDataToEndOfFile()`
                // — the same shape as `ProcessGitCommandRunner.runSync`, and
                // load-bearing now that the drain below is bounded.
                //
                // `readDataToEndOfFile()` assigns only once it has read
                // EVERYTHING. Pair that with a bounded wait and an expiry
                // leaves `outData` as the empty `Data()` it was initialised
                // with, so a SUCCESSFUL git reports empty stdout: exit code 0,
                // no output, no error. Callers assert on that stdout
                // (`ls-tree`, `log --oneline`, `show`), so it is an invisible
                // way to fail a test for a reason unrelated to what it tests.
                // Appending as chunks arrive means whatever was read survives.
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData   // blocks until data or EOF
                    if chunk.isEmpty { break }
                    lock.lock()
                    if isStdout { outData.append(chunk) } else { errData.append(chunk) }
                    lock.unlock()
                }
                drain.leave()
            }
        }
        // Both waits are BOUNDED (issue #208), mirroring
        // `ProcessGitCommandRunner.runSync`. They used to be
        // `process.waitUntilExit()` / `drain.wait()` with no deadline, which
        // meant a single wedged `git` in `setUp` hung this test until XCTest
        // killed the test host — a red run naming a test with no reason
        // attached, and one the retry policy cannot recover. See
        // `gitCommandTimeout` for why that distinction is the whole point.
        //
        // The exit is now observed by `terminationHandler` (installed above)
        // with `waitUntilExit()` on a dedicated thread as a backstop, rather
        // than by a `waitUntilExit()` parked on the global queue. That is what
        // produced this suite's most legible failure to date (issue #246):
        //
        //     git checkout -b main did not exit within 60s and was killed
        //       (stderr so far: Switched to a new branch 'main'
        //
        // `Switched to a new branch 'main'` is git's own success message, so
        // git had run, succeeded, and written to a pipe we were reading — and
        // 65s later the work item meant to notice its exit still had not been
        // scheduled.
        BlockingWork.onDedicatedThread(named: "mila.test.git.reap") {
            process.waitUntilExit()
            exited.signal()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + .seconds(Int(Self.gitCommandTimeout))) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 3)
            }
        }
        // Bounded too: EOF is not guaranteed even after exit, because a helper
        // `git` spawned can inherit the pipes and outlive it. See
        // `pipeDrainTimeout` for why the bound is generous.
        let drained = drain.wait(timeout: .now() + .seconds(Int(Self.pipeDrainTimeout))) != .timedOut
        // Take the lock: unlike an unbounded `drain.wait()`, the readers are
        // not guaranteed to be finished here.
        lock.lock()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        // Byte counts for the diagnostic below, snapshotted here: on the
        // timed-out path the readers may still be appending, so reading
        // `outData.count` outside the lock would itself be a data race.
        let stdoutBytes = outData.count, stderrBytes = errData.count
        lock.unlock()
        if timedOut {
            throw NSError(domain: "git", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) "
                    + "did not exit within \(Int(Self.gitCommandTimeout))s and was killed"
                    + " (stderr so far: \(stderr))"
            ])
        }
        // A drain that expired means `stdout` may be TRUNCATED. Returning it
        // would hand the caller a short answer that looks like a real one —
        // `files.contains("a.md")` would simply be false — which is the
        // silently-wrong outcome this whole branch exists to remove. Fail
        // loudly instead, and say how much did arrive.
        guard drained else {
            throw NSError(domain: "git", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) "
                    + "exited but its pipes did not reach EOF within "
                    + "\(Int(Self.pipeDrainTimeout))s — refusing to report "
                    + "possibly-truncated output (\(stdoutBytes) bytes stdout, "
                    + "\(stderrBytes) bytes stderr so far)"
            ])
        }
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
