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

    /// Per-spawn bound for the echo scripts. Nothing here does more than
    /// `printf`, so this is a hang detector, not a budget.
    ///
    /// It has to stay well under CI's 240s `-default-test-execution-time-`
    /// `allowance` MULTIPLIED BY the number of children a test spawns, plus
    /// each child's kill grace (~6s) — over the allowance XCTest kills the
    /// test host, which records no message and cannot be retried, which is the
    /// whole subject of #245. Four spawns at 30s + grace is ~156s worst case.
    private static let spawnTimeout: TimeInterval = 30

    /// `test_a_oneshot_run_does_not_sweep_a_concurrent_tick` holds a child
    /// inside the sandbox for as long as the rest of the test takes, so its
    /// bound must EXCEED every wait that has to finish before the barrier
    /// releasing it can be written. `test_tick_budget_exceeds_the_waits_it_`
    /// `spans` pins that; the numbers below are what makes it true.
    private static let tickTimeout: TimeInterval = 120
    /// Time allowed for the tick to spawn and write its handshake file.
    private static let tickReadyTimeout: TimeInterval = 20

    /// A stand-in for `claude -p` that reports where it ran and what it was
    /// told, so one invocation can answer both questions. The cwd assertions
    /// can't speak to argv, which is what let the session-UUID claim go
    /// unchecked.
    ///
    /// Three markers, and the middle one is the important one:
    ///
    ///     CWD:<pwd>          one line
    ///     ARGC:<count>       one line — `$#`, taken before any joining
    ///     ARGV:<joined>      NOT one line: `$*` carries the prompt's newlines
    ///
    /// `ARGC` exists because `ARGV` alone cannot tell "the CLI was never given
    /// `--session-id`" apart from "our parse of `$*` dropped it". `$*` also
    /// collapses argument boundaries, so a count taken before the join is the
    /// only value here that can see an argument disappear. The first version
    /// of this fixture had no count and a line-wise parse, and CI reported
    /// `argv was: -p x` — on its face indistinguishable from a production
    /// regression that had stopped passing the session flag.
    private func makeCWDAndArgvEchoScript() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-mila-sandbox-test-\(UUID().uuidString).sh")
        try? ("#!/bin/sh\n"
              + "printf 'CWD:%s\\n' \"$PWD\"\n"
              + "printf 'ARGC:%s\\n' \"$#\"\n"
              + "printf 'ARGV:%s\\n' \"$*\"\n").write(
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

    /// Writes `marker` into its cwd (the sandbox), signals `ready`, parks until
    /// `barrier` appears, then reports whether its own file survived the wait.
    /// `ready` and `barrier` both live OUTSIDE the sandbox so the handshake
    /// itself writes nothing into the directory under test.
    private func makeMarkerHolderScript(marker: String, ready: URL, barrier: URL) -> URL {
        makeScript("""
        #!/bin/sh
        printf 'output derived from a meeting transcript' > "\(marker)"
        : > "\(ready.path)"
        i=0
        while [ ! -f "\(barrier.path)" ] && [ $i -lt 1200 ]; do
          i=$((i+1)); sleep 0.05
        done
        if [ -e "\(marker)" ]; then printf 'TICK:FOUND'; else printf 'TICK:ABSENT'; fi
        """)
    }

    private func makeScript(_ body: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("island-mila-sandbox-test-\(UUID().uuidString).sh")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return url
    }

    /// Poll for a handshake file. `XCTFail` rather than a `throw` on expiry so
    /// the failure names the file that never appeared instead of surfacing as
    /// an opaque error out of the caller.
    private func waitForFile(_ url: URL,
                             timeout: TimeInterval,
                             file: StaticString = #filePath,
                             line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out after \(Int(timeout))s waiting for \(url.lastPathComponent)",
                file: file, line: line)
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
    /// The preferred root is Application Support, not $TMPDIR -- macOS rotates
    /// and purges the per-user temp directory, which would fragment the Claude
    /// project directory again over time.
    ///
    /// Asserted against the *pure* path builder rather than
    /// `sandboxDirectory()`, because that one deliberately falls back to a temp
    /// directory when Application Support cannot be created. Asserting "never
    /// under $TMPDIR" on the impure call would fail exactly when the documented
    /// fallback is working.
    func test_sandbox_layout_is_the_same_under_either_root() {
        let appSupport = URL(fileURLWithPath: "/Users/someone/Library/Application Support",
                             isDirectory: true)
        let temp = URL(fileURLWithPath: "/var/folders/xx/T", isDirectory: true)
        for root in [appSupport, temp] {
            let url = LLMRunner.sandboxDirectory(appSupportRoot: root)
            XCTAssertTrue(url.path.hasPrefix(root.path),
                          "sandbox escaped its root: \(url.path)")
            XCTAssertTrue(url.path.hasSuffix("/Mila/llm-sandbox"),
                          "sandbox layout changed: \(url.path)")
        }
    }

    func test_sandboxDirectory_is_stable_and_exists() {
        let first = LLMRunner.sandboxDirectory()
        let second = LLMRunner.sandboxDirectory()
        XCTAssertEqual(first, second, "sandbox directory is not stable across calls")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path),
                      "sandbox directory was not created: \(first.path)")
        XCTAssertTrue(first.path.contains("/Mila/llm-sandbox"),
                      "sandbox is not under Mila's own directory: \(first.path)")
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
                                            timeout: Self.spawnTimeout)
        let second = try await LLMRunner.run(tool: .claude,
                                             prompt: "x", transcript: "y",
                                             executablePathOverride: script.path,
                                             timeout: Self.spawnTimeout)
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
        // ONE script that echoes both the cwd and argv, used for all four
        // runs (issue #246). This test used to spawn six children: four
        // cwd-only runs, then two more that re-ran the session/resume pair
        // just to look at argv. Six children at `spawnTimeout` each, plus
        // their kill grace, put the worst case within sight of CI's 240s
        // per-test allowance — and over that line XCTest kills the test host
        // instead of failing the test, which is unretryable and reports no
        // reason (#245). Four children asserting BOTH properties on every run
        // is strictly more coverage for two-thirds of the spawns.
        let script = makeCWDAndArgvEchoScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let id = UUID()
        let oneShot = try await runEcho(script)
        let newSession = try await runEcho(script, session: .new(id))
        let resumed = try await runEcho(script, session: .resume(id))
        let other = try await runEcho(script, session: .new(UUID()))
        // Diagnostics, not a new contract (issue #208): this test failed once
        // on PR #242 and passed on a rerun of the same code, so the next
        // occurrence should at least name itself. `runEcho` carries the bulk
        // of that guard now — a run that produced no output fails there, by
        // name, instead of arriving here as `"" == ""`. This is the last
        // remaining hole: a child that printed the markers and nothing after
        // them.
        XCTAssertFalse(oneShot.cwd.isEmpty,
                       "the child printed no cwd at all — the run produced no "
                       + "output rather than the wrong output, so the "
                       + "comparisons below prove nothing")
        XCTAssertEqual(newSession.cwd, oneShot.cwd)
        XCTAssertEqual(resumed.cwd, oneShot.cwd)
        XCTAssertEqual(other.cwd, oneShot.cwd,
                       "a second session got its own CWD — one project "
                       + "directory per Live AI session, which is the leak")
        // The cwd must not carry the UUID...
        XCTAssertFalse(newSession.cwd.contains(id.uuidString),
                       "session UUID leaked into the CWD: \(newSession.cwd)")

        // ...but the UUID does have to reach the CLI, because that is what
        // keeps the conversations apart inside the one shared project. The cwd
        // assertions cannot show it: "UUID absent from the cwd" is equally
        // consistent with "never passed at all". Now checked on the SAME runs
        // rather than on two extra spawns.
        //
        // Assert the COUNT before the contents. `LLMTool.arguments` adds
        // exactly two arguments for a session (`--session-id <uuid>` for
        // `.new`, `--resume <uuid>` for `.resume`) and nothing else differs
        // between these four runs, so the delta is exactly 2. That check
        // depends on no string matching at all, which matters twice: it
        // catches a production path that stopped emitting the flag — every
        // Live AI tick would then silently start a fresh conversation instead
        // of continuing the meeting — and it cannot be satisfied by a uuid
        // that merely appears somewhere in the output.
        XCTAssertEqual(newSession.argc, oneShot.argc + 2,
                       "a new session must add `--session-id <uuid>`: "
                       + "\(newSession.argc) arguments vs \(oneShot.argc) for the one-shot")
        XCTAssertEqual(resumed.argc, oneShot.argc + 2,
                       "a resumed session must add `--resume <uuid>`: "
                       + "\(resumed.argc) arguments vs \(oneShot.argc) for the one-shot")
        XCTAssertTrue(newSession.argv.contains(id.uuidString),
                      "a new session must pass its UUID to the CLI; argv was: \(newSession.argv)")
        XCTAssertTrue(resumed.argv.contains(id.uuidString),
                      "a resumed session must pass its UUID to the CLI; argv was: \(resumed.argv)")
        // The negative half, which the old shape never checked: a run with no
        // session must not carry one, and a different session must not carry
        // this one's id.
        XCTAssertFalse(oneShot.argv.contains(id.uuidString),
                       "a one-shot run must not carry a session id; argv was: \(oneShot.argv)")
        XCTAssertFalse(other.argv.contains(id.uuidString),
                       "a different session reused this session's id; argv was: \(other.argv)")
    }

    /// One run of `makeCWDAndArgvEchoScript`, split back into its three parts.
    private struct EchoedRun {
        let cwd: String
        /// `$#` — the count BEFORE `$*` joined everything with spaces. The
        /// only value here that can detect an argument going missing.
        let argc: Int
        let argv: String
    }

    /// Run the echo script and split its output at the three markers.
    ///
    /// Parsing rather than asserting on the raw string because
    /// `executeProcess` has a documented path that returns an EMPTY string
    /// from a SUCCESSFUL run: on normal exit it waits a bounded time for the
    /// pipe readers to reach EOF and, on expiry, logs and returns whatever it
    /// buffered — exit code 0, `timedOut` false. Left as a raw comparison that
    /// is either inscrutable (`"" != "/path/…"`) or, when it hits every run,
    /// invisible: four empty strings compare equal and the test passes having
    /// proven nothing. Missing markers fail here, by name.
    private func runEcho(_ script: URL,
                         session: LLMSession = .none,
                         file: StaticString = #filePath,
                         line: UInt = #line) async throws -> EchoedRun {
        let output = try await LLMRunner.run(tool: .claude,
                                             prompt: "x", transcript: "y",
                                             executablePathOverride: script.path,
                                             session: session,
                                             timeout: Self.spawnTimeout)
        // Split on the MARKERS, never on newlines. `CWD:` and `ARGC:` are one
        // line each, but `ARGV:` is not — the composed prompt is a single argv
        // element containing newlines, so argv runs from its marker to the end
        // of the output. A line-wise parse truncates it to `-p x` and then
        // fails the UUID assertions on a run that passed the UUID correctly;
        // CI caught exactly that on the first version of this helper.
        guard output.hasPrefix("CWD:"),
              let argcMarker = output.range(of: "\nARGC:"),
              let argvMarker = output.range(of: "\nARGV:"),
              argcMarker.upperBound <= argvMarker.lowerBound,
              let argc = Int(output[argcMarker.upperBound..<argvMarker.lowerBound]) else {
            XCTFail("the child produced no CWD:/ARGC:/ARGV: markers — a "
                    + "successful run with no output proves nothing. Got: "
                    + "\(output.debugDescription)",
                    file: file, line: line)
            return EchoedRun(cwd: "", argc: 0, argv: "")
        }
        return EchoedRun(cwd: String(output[..<argcMarker.lowerBound].dropFirst("CWD:".count)),
                         argc: argc,
                         argv: String(output[argvMarker.upperBound...]))
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
                                    timeout: Self.spawnTimeout)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: LLMRunner.sandboxDirectory().path),
            "shared sandbox was torn down after the run")
    }

    /// Issue #190's hard constraint: the sweep that keeps the shared directory
    /// clean must never delete a file a CONCURRENT invocation is using. Driven
    /// through the lease API directly rather than through two child processes
    /// so the overlap is exact and the test carries no subprocess timing — the
    /// end-to-end twin is `test_a_oneshot_run_does_not_sweep_a_concurrent_tick`
    /// below.
    ///
    /// Reads as the life of one Live AI tick with a one-shot Send landing on
    /// top of it: the tick writes something, the Send starts and finishes
    /// around it, and only when the last invocation leaves does the directory
    /// get emptied.
    func test_sweep_waits_for_the_last_concurrent_invocation() throws {
        let first = LLMRunner.acquireSandbox()
        var firstReleased = false
        defer { if !firstReleased { LLMRunner.releaseSandbox(first) } }

        let marker = first.appendingPathComponent(
            "island-mila-inflight-\(UUID().uuidString).txt")
        try Data("a file the running invocation is using".utf8).write(to: marker)
        // Control for the three assertions below: they are only meaningful if
        // the file was really there to begin with.
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "test setup failed: nothing was written at \(marker.path)")

        // A second invocation STARTING while the first is still inside must not
        // sweep — this is the "deleted a file out from under a live child"
        // case that rules out a naive sweep-before-each-run.
        let second = LLMRunner.acquireSandbox()
        var secondReleased = false
        defer { if !secondReleased { LLMRunner.releaseSandbox(second) } }
        XCTAssertEqual(second, first,
                       "concurrent invocations must still share one cwd (#181)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "a second invocation swept a file the first one is using")

        // Nor may it sweep on the way out, while the first is still inside.
        LLMRunner.releaseSandbox(second)
        secondReleased = true
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the sweep fired while an invocation was still running")

        // Last one out empties the directory.
        LLMRunner.releaseSandbox(first)
        firstReleased = true
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path),
                       "the shared sandbox kept an artifact after the last "
                       + "invocation left: \(marker.path)")
    }

    /// The budget invariant behind `test_a_oneshot_run_does_not_sweep_a_`
    /// `concurrent_tick`, asserted separately so it is checked in
    /// milliseconds instead of only being discovered by a two-minute timeout.
    ///
    /// The tick's clock starts when it is spawned, but it cannot RETURN until
    /// the barrier is written — and the barrier is written only after the two
    /// waits above it have finished. So its budget has to exceed their sum, or
    /// the test times out its own child by construction.
    ///
    /// It did: the bounds were 120 for the tick and 60 + 60 for the waits it
    /// spans, i.e. exactly zero margin, and it survived only because both
    /// waits normally take milliseconds. It was observed failing with
    /// `timedOut(seconds: 120)` at 126.8s (issue #246).
    ///
    /// The fix is NOT a bigger tick budget — 120s is already half of CI's 240s
    /// per-test allowance, and crossing that swaps an ordinary retryable
    /// failure for a test-host kill (#245). It is a smaller sum, checked here
    /// so the next person to touch a number finds out immediately.
    func test_tick_budget_exceeds_the_waits_it_spans() {
        XCTAssertGreaterThan(Self.tickTimeout,
                             2 * (Self.tickReadyTimeout + Self.spawnTimeout),
                             "the concurrent-tick test cannot release its tick "
                             + "until \(Self.tickReadyTimeout)s + "
                             + "\(Self.spawnTimeout)s of waits have elapsed, so a "
                             + "\(Self.tickTimeout)s tick budget leaves no margin")
        XCTAssertLessThan(Self.tickTimeout, 240,
                          "a bound at or above CI's -default-test-execution-time-"
                          + "allowance makes XCTest kill the test HOST rather "
                          + "than fail the test — no message, and no retry")
    }

    /// The same property with real children, because the lease test cannot show
    /// that `executeProcess` actually holds its lease for the whole life of the
    /// child rather than just across the launch.
    ///
    /// A long-running invocation (the shape of a Live AI tick) writes a file
    /// into the shared cwd and parks on a barrier; a one-shot call then starts
    /// AND finishes around it. Neither the one-shot's entry nor its exit may
    /// take the tick's file with it.
    func test_a_oneshot_run_does_not_sweep_a_concurrent_tick() async throws {
        let token = UUID().uuidString
        let temp = FileManager.default.temporaryDirectory
        let ready = temp.appendingPathComponent("island-mila-tick-ready-\(token)")
        let barrier = temp.appendingPathComponent("island-mila-tick-barrier-\(token)")
        let tick = makeMarkerHolderScript(marker: "island-mila-tick-artifact-\(token).txt",
                                          ready: ready,
                                          barrier: barrier)
        let oneShot = makeCWDEchoScript()
        defer {
            for url in [ready, barrier, tick, oneShot] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        async let live = LLMRunner.run(tool: .claude, prompt: "x", transcript: "y",
                                       executablePathOverride: tick.path,
                                       session: .new(UUID()),
                                       timeout: Self.tickTimeout)
        // Don't start the one-shot until the tick is genuinely inside with its
        // file written — otherwise the two might not overlap at all and the
        // test would pass without exercising anything.
        try await waitForFile(ready, timeout: Self.tickReadyTimeout)

        let oneShotCWD = try await LLMRunner.run(tool: .claude,
                                                 prompt: "x", transcript: "y",
                                                 executablePathOverride: oneShot.path,
                                                 timeout: Self.spawnTimeout)
        XCTAssertEqual(oneShotCWD, LLMRunner.sandboxDirectory().path,
                       "the one-shot didn't run in the shared sandbox, so it "
                       + "never had the chance to sweep the tick's file")

        try Data().write(to: barrier)
        let tickResult = try await live
        XCTAssertEqual(tickResult, "TICK:FOUND",
                       "a concurrent one-shot swept the running tick's file out "
                       + "from under it: \(tickResult)")
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
                                              timeout: Self.spawnTimeout)
        XCTAssertTrue(result.succeeded, "diagnose failed: \(result)")
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       LLMRunner.sandboxDirectory().path)
    }
}
