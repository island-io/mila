import XCTest

/// UI tests for the "app-record auto-drop on silence" feature: when a
/// meeting recording targets an app that produces no audio for the
/// opening window, the system-audio leg is silently torn down and the
/// recording continues with mic-only audio.
///
/// Both tests use the launch-arg-driven fake-meeting seam in
/// `MilaApp.startFakeMeetingIfRequested()` so they don't depend on
/// ScreenCaptureKit (which needs TCC grants) or BlackHole-style virtual
/// loopbacks (flaky on CI runners). The fake seam:
///   * Flips RecordingSession into `.meeting` state
///   * Arms the silence monitor with the configured window override
///     (10s in tests; 5 minutes in production)
///   * For "with-audio" mode, pumps synthetic non-silence buffers into
///     the monitor at 20Hz
///
/// Tests poll a status file because OSLog isn't readable from
/// XCUITest. The session writes "active" on start and "dropped" when
/// the monitor's silence window fires the auto-drop.
///
/// Gated on `MILA_SILENCE_E2E=1` (delivered via
/// `TEST_RUNNER_MILA_SILENCE_E2E` in xcodebuild env, same plumbing as
/// the other UI-test suites — plain shell envs don't propagate to the
/// runner).
final class RecordingSilenceUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Silent app: no audio buffers feed the monitor for 10s. The
    /// session should observe the window expire and tear down the
    /// system-audio leg. The mic stays alive (we don't observe mic in
    /// this test — that would require AVAudioEngine, which we're
    /// avoiding — but the production `dropSystemAudioLeg` path leaves
    /// micTask untouched).
    func test_silent_app_drops_system_audio_after_window() throws {
        try gate()
        let statusFile = makeStatusFile()
        let app = launchApp(mode: "silent", statusFile: statusFile)
        defer { app.terminate() }

        // Confirm the session actually started in the "active" state
        // before the window. If this never trips, the launch-arg
        // pipeline is broken — fail fast rather than waste the test
        // budget polling for a "dropped" that can never come.
        XCTAssertTrue(
            waitForStatus("active", file: statusFile, timeout: 5),
            "Status file never reached 'active' — fake-meeting launch arg didn't take effect"
        )

        // Window is 10s; allow generous slack for the deadline task
        // to fire + the status-file write to land.
        XCTAssertTrue(
            waitForStatus("dropped", file: statusFile, timeout: 25),
            "System-audio leg was not dropped within 25s of a 10s silence window"
        )
    }

    /// Audio-producing app: the fake-meeting seam pumps a non-silent
    /// buffer (0.05 amplitude, well above the 0.001 RMS threshold) at
    /// 20Hz. The monitor should observe audio on the very first
    /// ingest and the window should pass without a drop.
    func test_audio_app_keeps_system_audio_active() throws {
        try gate()
        let statusFile = makeStatusFile()
        let app = launchApp(mode: "with-audio", statusFile: statusFile)
        defer { app.terminate() }

        XCTAssertTrue(
            waitForStatus("active", file: statusFile, timeout: 5),
            "Status file never reached 'active' — fake-meeting launch arg didn't take effect"
        )

        // Wait past the 10s window. If a drop ever happened the file
        // would now contain "dropped". We also assert it stays at
        // "active" right up to the end so a delayed drop doesn't
        // sneak in.
        Thread.sleep(forTimeInterval: 18)
        let final = readStatus(file: statusFile)
        XCTAssertEqual(
            final, "active",
            "System-audio leg was dropped despite audio being present (status=\(final ?? "nil"))"
        )
    }

    // MARK: - Helpers

    private func gate() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MILA_SILENCE_E2E"] == "1",
            "Set MILA_SILENCE_E2E=1 (via TEST_RUNNER_MILA_SILENCE_E2E in xcodebuild env) to run."
        )
    }

    /// Make a per-test status file in a temp dir. Pre-create as
    /// "pending" so a status-read race (file not yet written) is
    /// distinguishable from a real "active"/"dropped" value.
    private func makeStatusFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-silence-\(UUID().uuidString).status")
        try? "pending".data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    private func launchApp(mode: String, statusFile: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--uitests",
            "--ui-test-silence-window-seconds=10",
            "--ui-test-silence-status-file=\(statusFile.path)",
            "--ui-test-fake-meeting=\(mode)",
        ]
        app.launch()
        return app
    }

    private func readStatus(file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Poll the status file for the expected value. Returns true if
    /// the value is observed within `timeout` seconds; false on
    /// timeout. 0.25s poll interval is responsive enough without
    /// busy-spinning.
    private func waitForStatus(_ expected: String, file: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readStatus(file: file) == expected { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }
}
