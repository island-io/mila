import XCTest
@testable import Mila

/// Issue #181 — "every LLM invocation creates a new ~/.claude/projects
/// directory".
///
/// The LLM CLIs Mila drives derive their session store from the process
/// working directory: `claude` writes
/// `~/.claude/projects/<slug-of-cwd>/<session-uuid>.jsonl`. Mila used to hand
/// every invocation its own cwd — `$TMPDIR/island-mila-llm-<UUID>` for
/// one-shot calls, `$TMPDIR/island-mila-llm-session-<UUID>` for Live AI ticks
/// — so every invocation minted a project directory that nothing ever
/// removed (175 of them, 46 MB, in the report) and that was unresumable
/// because Mila deleted the cwd it was named after.
///
/// These tests pin the fix: ONE stable working directory for every path into
/// `executeProcess`, with session identity still carried by the `--session-id`
/// / `--resume` UUID rather than by the cwd.
///
/// Kept in its own class (not `LLMRunnerTests`) so it can be run on its own —
/// `LLMRunnerTests` also holds smoke tests that invoke the real `claude` /
/// `cursor-agent` / `gemini` binaries.
final class LLMSandboxDirectoryTests: XCTestCase {

    /// A stand-in for `claude -p` that just prints its working directory.
    /// Prints the cwd and then its whole argv, on separate marked lines, so a
    /// test can assert both "where did it run" and "what was it told" from one
    /// invocation. The cwd assertions can't speak to argv, which is what let
    /// the session-UUID claim go unchecked.
    private func makeCWDAndArgvEchoScript() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-mila-sandbox-test-\(UUID().uuidString).sh")
        try? "#!/bin/sh\nprintf 'CWD:%s\\n' \"$PWD\"\nprintf 'ARGV:%s\\n' \"$*\"\n".write(
            to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url
    }

    /// Blocks until `barrier` exists, then prints the cwd — so two runs can be
    /// proven genuinely concurrent (both inside the sandbox at once) rather
    /// than merely sequential. The barrier lives OUTSIDE the sandbox so the
    /// synchronisation itself doesn't write into the directory under test.
    private func makeBarrierCWDScript(barrier: URL) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-mila-sandbox-test-\(UUID().uuidString).sh")
        let body = """
        #!/bin/sh
        i=0
        while [ ! -f "\(barrier.path)" ] && [ $i -lt 300 ]; do
          i=$((i+1)); sleep 0.05
        done
        printf '%s' "$PWD"
        """
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url
    }

    private func makeCWDEchoScript() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-mila-sandbox-test-\(UUID().uuidString).sh")
        try? "#!/bin/sh\nprintf '%s' \"$PWD\"\n".write(to: url,
                                                        atomically: true,
                                                        encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url
    }

    /// claude derives its `~/.claude/projects/<slug-of-cwd>` project directory
    /// from the process CWD. A per-invocation CWD therefore leaked a
    /// per-invocation project directory that nothing ever cleaned up (175
    /// orphans / 46 MB in the report). The path must contain nothing
    /// run-specific — no UUID, no PID, no timestamp.
    func test_sandbox_path_has_no_per_run_component() {
        let root = URL(fileURLWithPath: "/tmp/fake-app-support", isDirectory: true)
        let first = LLMRunner.sandboxDirectory(appSupportRoot: root)
        let second = LLMRunner.sandboxDirectory(appSupportRoot: root)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.path, "/tmp/fake-app-support/Mila/llm-sandbox")
    }

    /// The real resolver must be stable across calls, live under Mila's own
    /// Application Support directory (so the `~/.claude/projects` slug
    /// survives reboots and $TMPDIR purges), and actually exist — `Process`
    /// refuses to launch into a missing `currentDirectoryURL`.
    func test_sandboxDirectory_is_stable_and_exists() {
        let first = LLMRunner.sandboxDirectory()
        let second = LLMRunner.sandboxDirectory()
        XCTAssertEqual(first, second, "sandbox directory is not stable across calls")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path),
                      "sandbox directory was not created: \(first.path)")
        XCTAssertTrue(first.path.contains("/Mila/llm-sandbox"),
                      "sandbox is not under Mila's own directory: \(first.path)")
        // Not $TMPDIR: macOS rotates and purges the per-user temp directory,
        // which would fragment the project directory again over time.
        XCTAssertFalse(first.path.hasPrefix(FileManager.default.temporaryDirectory.path),
                       "sandbox is under $TMPDIR: \(first.path)")
        XCTAssertEqual(first.lastPathComponent, "llm-sandbox",
                       "sandbox name looks run-specific: \(first.lastPathComponent)")
    }

    /// The actual leak, end to end: two separate invocations must land in the
    /// SAME cwd, so claude files them as two sessions of one project instead
    /// of two projects. Covers the one-shot path (title generation, the
    /// Settings test button, the post-recording action).
    func test_two_oneshot_runs_share_one_working_directory() async throws {
        let script = makeCWDEchoScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let first = try await LLMRunner.run(tool: .claude,
                                            prompt: "x", transcript: "y",
                                            executablePathOverride: script.path,
                                            timeout: 30)
        let second = try await LLMRunner.run(tool: .claude,
                                             prompt: "x", transcript: "y",
                                             executablePathOverride: script.path,
                                             timeout: 30)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second,
                       "each invocation got its own CWD — that is one leaked "
                       + "~/.claude/projects directory per run")
    }

    /// Session-carrying runs (Live AI ticks, `--session-id` / `--resume`) must
    /// share that same one directory too. Session identity comes from the UUID
    /// in argv, never from the cwd, so `--resume` continuity survives — while
    /// a per-session cwd would mint a project directory per recording.
    func test_session_runs_share_the_same_directory_as_oneshot_runs() async throws {
        let script = makeCWDEchoScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let oneShot = try await LLMRunner.run(tool: .claude,
                                              prompt: "x", transcript: "y",
                                              executablePathOverride: script.path,
                                              timeout: 30)
        let id = UUID()
        let newSession = try await LLMRunner.run(tool: .claude,
                                                 prompt: "x", transcript: "y",
                                                 executablePathOverride: script.path,
                                                 session: .new(id),
                                                 timeout: 30)
        let resumed = try await LLMRunner.run(tool: .claude,
                                               prompt: "x", transcript: "y",
                                               executablePathOverride: script.path,
                                               session: .resume(id),
                                               timeout: 30)
        let other = try await LLMRunner.run(tool: .claude,
                                             prompt: "x", transcript: "y",
                                             executablePathOverride: script.path,
                                             session: .new(UUID()),
                                             timeout: 30)
        XCTAssertEqual(newSession, oneShot)
        XCTAssertEqual(resumed, oneShot)
        XCTAssertEqual(other, oneShot,
                       "a second session got its own CWD — one project "
                       + "directory per Live AI session, which is the leak")
        // The cwd must not carry the UUID...
        XCTAssertFalse(newSession.contains(id.uuidString),
                       "session UUID leaked into the CWD: \(newSession)")

        // ...but the UUID does have to reach the CLI, because that is what
        // keeps the conversations apart inside the one shared project. The
        // assertion above cannot show it: this script echoes only the cwd, so
        // "UUID absent" is equally consistent with "never passed at all".
        // Check argv directly.
        let argvScript = makeCWDAndArgvEchoScript()
        defer { try? FileManager.default.removeItem(at: argvScript) }
        let newOut = try await LLMRunner.run(tool: .claude,
                                             prompt: "x", transcript: "y",
                                             executablePathOverride: argvScript.path,
                                             session: .new(id),
                                             timeout: 30)
        let resumedOut = try await LLMRunner.run(tool: .claude,
                                                 prompt: "x", transcript: "y",
                                                 executablePathOverride: argvScript.path,
                                                 session: .resume(id),
                                                 timeout: 30)
        XCTAssertTrue(newOut.contains(id.uuidString),
                      "a new session must pass its UUID to the CLI; argv was: \(newOut)")
        XCTAssertTrue(resumedOut.contains(id.uuidString),
                      "a resumed session must pass its UUID to the CLI; argv was: \(resumedOut)")
    }

    /// The PR claims concurrent invocations can share one cwd. Sequential runs
    /// cannot show that -- they never overlap. Here both processes are held
    /// inside the sandbox simultaneously on a barrier that lives outside it,
    /// then released, so the shared-cwd result is observed under genuine
    /// concurrency.
    func test_concurrent_runs_share_one_working_directory() async throws {
        let barrier = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-mila-barrier-\(UUID().uuidString)")
        let script = makeBarrierCWDScript(barrier: barrier)
        defer {
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: barrier)
        }

        async let first = LLMRunner.run(tool: .claude, prompt: "x", transcript: "y",
                                        executablePathOverride: script.path, timeout: 60)
        async let second = LLMRunner.run(tool: .claude, prompt: "x", transcript: "y",
                                         executablePathOverride: script.path, timeout: 60)

        // Both children are now spinning on the barrier; release them together.
        try await Task.sleep(for: .milliseconds(300))
        try Data().write(to: barrier)

        let (a, b) = try await (first, second)
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a, b, "concurrent invocations must share the one sandbox cwd")
    }

    /// The runner must not delete the shared directory after a run — a
    /// subsequent `Process.run()` would fail outright on a missing cwd, and
    /// the deleted-cwd design is exactly what made past conversations
    /// unresumable by hand.
    func test_runner_leaves_the_shared_directory_in_place() async throws {
        let script = makeCWDEchoScript()
        defer { try? FileManager.default.removeItem(at: script) }
        _ = try await LLMRunner.run(tool: .claude,
                                    prompt: "x", transcript: "y",
                                    executablePathOverride: script.path,
                                    timeout: 30)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: LLMRunner.sandboxDirectory().path),
            "shared sandbox was torn down after the run")
    }

    /// `diagnose` (Settings → AI Provider "Test") is the third code path into
    /// `executeProcess`; it used to take the ephemeral branch. It must land in
    /// the shared directory as well.
    func test_diagnose_runs_in_the_shared_directory() async {
        let script = makeCWDEchoScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let result = await LLMRunner.diagnose(tool: .claude,
                                              prompt: "x", transcript: "y",
                                              executablePathOverride: script.path,
                                              timeout: 30)
        XCTAssertTrue(result.succeeded, "diagnose failed: \(result)")
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       LLMRunner.sandboxDirectory().path)
    }
}
