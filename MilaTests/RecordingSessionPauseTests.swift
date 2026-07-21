import XCTest
@testable import Mila

/// Tests for the pause/resume additions to `RecordingSession`. The audio
/// engine itself can't run on CI, so these cover the parts that don't need
/// it: the pure elapsed-time accounting and the state machine driven via
/// the fake-start seam (`startFakeForTesting`).
@MainActor
final class RecordingSessionPauseTests: XCTestCase {

    // MARK: - Pure elapsed accounting

    func test_elapsed_excludes_paused_time() {
        let start = Date()
        let now = start.addingTimeInterval(30)
        XCTAssertEqual(RecordingSession.elapsed(now: now, startTime: start, totalPaused: 0),
                       30, accuracy: 0.001)
        // 10s of that 30s wall-clock was spent paused → 20s of recorded time.
        XCTAssertEqual(RecordingSession.elapsed(now: now, startTime: start, totalPaused: 10),
                       20, accuracy: 0.001)
    }

    func test_elapsed_never_goes_negative() {
        let start = Date()
        // Clock skew / rounding must never produce a negative elapsed.
        XCTAssertEqual(RecordingSession.elapsed(now: start, startTime: start, totalPaused: 5),
                       0, accuracy: 0.001)
    }

    // MARK: - State machine

    func test_pause_and_resume_toggle_state() async {
        let session = RecordingSession()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-\(UUID().uuidString).wav")
        await session.startFakeForTesting(outputURL: url)
        XCTAssertTrue(session.state == .recording)

        session.pause()
        XCTAssertTrue(session.state == .paused)

        // Double-pause is a no-op.
        session.pause()
        XCTAssertTrue(session.state == .paused)

        session.resume()
        XCTAssertTrue(session.state == .recording)

        // Double-resume is a no-op.
        session.resume()
        XCTAssertTrue(session.state == .recording)

        _ = await session.stop()
        XCTAssertTrue(session.state == .idle)
    }

    func test_pause_and_resume_are_noops_when_idle() {
        let session = RecordingSession()
        XCTAssertTrue(session.state == .idle)
        session.pause()
        XCTAssertTrue(session.state == .idle)
        session.resume()
        XCTAssertTrue(session.state == .idle)
    }

    /// Stop must work while paused (the user can hit Stop without resuming
    /// first) and return the recording's URL, landing back at `.idle`.
    func test_stop_while_paused_returns_url_and_idles() async {
        let session = RecordingSession()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-stop-\(UUID().uuidString).wav")
        await session.startFakeForTesting(outputURL: url)
        session.pause()
        XCTAssertTrue(session.state == .paused)

        let out = await session.stop()
        XCTAssertEqual(out, url)
        XCTAssertTrue(session.state == .idle)
    }
}
