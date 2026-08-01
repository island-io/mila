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

    /// Several pauses in one recording must all be subtracted, not just the
    /// last one — `totalPaused` accumulates. Recomputing `elapsed`
    /// absolutely (rather than incrementing it per tick) is also what keeps
    /// the ≤200ms timer granularity from compounding across pauses.
    func test_elapsed_subtracts_every_pause_in_the_session() {
        let start = Date()
        let now = start.addingTimeInterval(600)     // 10 min door-to-door
        // Three pauses: 60 + 30 + 90 = 180s.
        XCTAssertEqual(RecordingSession.elapsed(now: now, startTime: start, totalPaused: 180),
                       420, accuracy: 0.001)
    }

    // MARK: - State machine

    func test_pause_and_resume_toggle_state() async {
        let session = RecordingSession()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-\(UUID().uuidString).wav")
        await session.startFakeForTesting(outputURL: url)
        XCTAssertTrue(session.state == .recording)

        await session.pause()
        XCTAssertTrue(session.state == .paused)

        // Double-pause is a no-op.
        await session.pause()
        XCTAssertTrue(session.state == .paused)

        session.resume()
        XCTAssertTrue(session.state == .recording)

        // Double-resume is a no-op.
        session.resume()
        XCTAssertTrue(session.state == .recording)

        _ = await session.stop()
        XCTAssertTrue(session.state == .idle)
    }

    func test_pause_and_resume_are_noops_when_idle() async {
        let session = RecordingSession()
        XCTAssertTrue(session.state == .idle)
        await session.pause()
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
        await session.pause()
        XCTAssertTrue(session.state == .paused)

        let out = await session.stop()
        XCTAssertEqual(out, url)
        XCTAssertTrue(session.state == .idle)
    }

    /// `cancelAll()` is the crash-adjacent path — app quit, sleep, lock
    /// screen. It must accept a paused session (its guard is `!= .idle`) and
    /// leave nothing behind that a following recording could inherit.
    func test_cancelAll_while_paused_returns_to_idle() async {
        let session = RecordingSession()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-cancel-\(UUID().uuidString).wav")
        await session.startFakeForTesting(outputURL: url)
        await session.pause()

        await session.cancelAll()
        XCTAssertTrue(session.state == .idle)
        XCTAssertEqual(session.elapsed, 0, accuracy: 0.001)
        XCTAssertNil(session.fileURL)

        // And the next recording starts clean rather than inheriting the
        // abandoned pause.
        let next = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-cancel-next-\(UUID().uuidString).wav")
        await session.startFakeForTesting(outputURL: next)
        XCTAssertTrue(session.state == .recording)
        _ = await session.stop()
    }

    /// The elapsed clock must freeze for the duration of a pause and pick up
    /// where it left off — never jump forward by the paused span on resume.
    /// This is the accounting that keeps `elapsed` equal to the length of the
    /// WAV, which `stopRecording`'s short-capture warning compares against.
    func test_elapsed_clock_freezes_across_a_real_pause() async throws {
        let session = RecordingSession()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-clock-\(UUID().uuidString).wav")
        await session.startFakeForTesting(outputURL: url)
        // Let the 200ms timer tick a couple of times.
        try await Task.sleep(nanoseconds: 500_000_000)
        await session.pause()
        let frozen = session.elapsed
        XCTAssertGreaterThan(frozen, 0, "the timer should have ticked before the pause")

        // Sit paused for meaningfully longer than the timer interval.
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertEqual(session.elapsed, frozen, accuracy: 0.001,
                       "elapsed must not advance while paused")

        session.resume()
        let resumedAt = Date()
        try await Task.sleep(nanoseconds: 400_000_000)
        let postResumeWall = Date().timeIntervalSince(resumedAt)
        let afterResume = session.elapsed
        XCTAssertGreaterThan(afterResume, frozen,
                             "the clock must restart on resume")
        // Budgeted off the MEASURED post-resume wall time rather than the
        // requested sleep, so a loaded CI runner overshooting its sleeps
        // can't fail this. If the 800ms pause leaked back in, `elapsed`
        // would exceed this by roughly the length of the pause.
        XCTAssertLessThanOrEqual(afterResume, frozen + postResumeWall + 0.3,
                                 "the paused span leaked back into elapsed (got \(afterResume), frozen \(frozen), post-resume wall \(postResumeWall))")

        _ = await session.stop()
    }

    // MARK: - Capture-recovery watchdog interaction

    /// A pause must not look like a dead microphone.
    ///
    /// `MicrophoneRecorder`'s stall watchdog rebuilds the engine when the
    /// capture frame count stops growing — and a self-triggering rebuild loop
    /// is exactly the production bug in issue #147. The reason a pause is
    /// safe is structural: the frame counter is incremented inside the audio
    /// tap, and `pause()` gates the buffer DOWNSTREAM of that in
    /// `consumeMic`. Pausing therefore leaves the counter advancing and the
    /// watchdog sees a healthy device.
    ///
    /// This pins the policy half of that with the real detector: as long as
    /// frames keep arriving, no stall is ever declared — however long the
    /// pause runs.
    func test_a_pause_that_keeps_the_tap_running_never_declares_a_stall() {
        var detector = CaptureStallDetector(timeout: 4.0)
        let start = Date()
        var frames = 0
        // Five minutes of "paused" at a realistic ~93ms tap cadence. The
        // buffers are all being discarded by RecordingSession; the tap that
        // feeds the counter is untouched.
        for tick in 0..<3200 {
            frames += 1024
            let now = start.addingTimeInterval(Double(tick) * 0.093)
            XCTAssertFalse(detector.observe(frames: frames, now: now),
                           "a running tap must never read as a stall, paused or not")
        }
    }

    /// The counterweight: if the device genuinely dies while the session is
    /// paused, the frame count DOES flatline and the watchdog still fires.
    /// Pause deliberately leaves the watchdog armed so the repair happens
    /// before the user resumes rather than four seconds after.
    func test_a_dead_device_still_stalls_while_paused() {
        var detector = CaptureStallDetector(timeout: 4.0)
        let start = Date()
        XCTAssertFalse(detector.observe(frames: 1024, now: start))
        XCTAssertFalse(detector.observe(frames: 1024, now: start.addingTimeInterval(1)))
        XCTAssertTrue(detector.observe(frames: 1024, now: start.addingTimeInterval(4.1)),
                      "a flatlined counter must still trip the watchdog during a pause")
    }

    // MARK: - Live-pipeline resume detection

    /// `MilaApp`'s live-pipeline observer decides "new recording" vs "resumed
    /// from a pause" off `captureEpoch`, because the `.paused` state in
    /// between is not guaranteed to be delivered to a `@Published` async
    /// consumer. Get this wrong and a resume re-runs `transcriber.start()`,
    /// which wipes the transcript the user has been reading.
    func test_captureEpoch_moves_only_on_a_new_recording() async {
        let session = RecordingSession()
        let first = FileManager.default.temporaryDirectory
            .appendingPathComponent("epoch-1-\(UUID().uuidString).wav")
        await session.startFakeForTesting(outputURL: first)
        let epochAtStart = session.captureEpoch

        await session.pause()
        XCTAssertEqual(session.captureEpoch, epochAtStart,
                       "pausing is not a new recording")
        session.resume()
        XCTAssertEqual(session.captureEpoch, epochAtStart,
                       "resuming is not a new recording — this is the guard that saves the live transcript")

        _ = await session.stop()
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("epoch-2-\(UUID().uuidString).wav")
        await session.startFakeForTesting(outputURL: second)
        XCTAssertGreaterThan(session.captureEpoch, epochAtStart,
                             "a genuinely new recording must be distinguishable")
        _ = await session.stop()
    }

    // MARK: - Level meters

    /// The level meters are driven from `consumeMic` / `consumeSystem`, which
    /// stop running while paused. Without an explicit zero they'd sit frozen
    /// at their last pre-pause reading and read as "still listening".
    func test_pause_zeroes_the_level_meters() async {
        let session = RecordingSession()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pause-levels-\(UUID().uuidString).wav")
        await session.startFakeForTesting(outputURL: url)
        await session.pause()
        XCTAssertEqual(session.micLevel, 0)
        XCTAssertEqual(session.systemLevel, 0)
        _ = await session.stop()
    }
}
