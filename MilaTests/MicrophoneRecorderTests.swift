import XCTest
import os
@testable import Mila

/// Regression coverage for the "wireless mic stalls CoreAudio and freezes the
/// whole app" bug. Before the fix, `MicrophoneRecorder.start()` was a sync
/// `@MainActor` method that called `inputFormat(forBus:)` directly on the
/// main thread — when the input device was a Bluetooth headset mid-profile-
/// switch, that call could `dispatch_sync` on the CoreAudio HAL queue for
/// many seconds, blocking the main thread → frozen UI + dead hotkeys.
///
/// These tests exercise the test-only `bringUpOverride` seam to simulate slow
/// CoreAudio without touching real hardware (so they're stable in CI).
@MainActor
final class MicrophoneRecorderTests: XCTestCase {

    func test_start_throws_timeout_when_bring_up_stalls_beyond_limit() async throws {
        let mic = MicrophoneRecorder()
        mic.bringUpTimeout = 0.15
        mic.bringUpOverride = {
            // Outlast the timeout. Real CoreAudio stalls would be a synchronous
            // dispatch_sync, but Task.sleep is enough to verify the timeout
            // race fires and that `start()` returns control to the caller.
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        let started = Date()
        do {
            try await mic.start()
            XCTFail("Expected MicrophoneError.bringUpTimedOut; start() returned successfully")
        } catch let error as MicrophoneError {
            XCTAssertEqual(error, .bringUpTimedOut)
            let elapsed = Date().timeIntervalSince(started)
            // Bound is generous for macos-26 GH VM jitter — same
            // flake class as the LLMRunner timeout test. The point
            // is "timeout fires" (vs. hangs forever), not ms precision.
            XCTAssertLessThan(elapsed, 5.0,
                              "Timeout should fire near the configured bound (0.15s); took \(elapsed)s")
        }
        await mic.stop()
    }

    /// Regression: the timeout must fire even when the bring-up stalls in an
    /// await that is NOT cancellation-responsive — which is exactly what the
    /// real path does (`realBringUp` awaits a detached task's `.value`, and
    /// the CoreAudio calls inside it can wedge indefinitely).
    ///
    /// The old `withThrowingTaskGroup`-based race could not exit until ALL
    /// children finished: the timeout child threw at the deadline, but the
    /// group then blocked awaiting the stuck operation child, so `start()`
    /// stayed suspended until (or forever, if) CoreAudio returned. The test
    /// above didn't catch this because its override stalls in a cancellable
    /// `Task.sleep`. This one mirrors the real path's non-cancellable
    /// structure: with the group race it returns only after the full 3s
    /// stall; with the first-wins race it returns at the 0.15s deadline.
    func test_timeout_fires_even_when_bring_up_is_not_cancellation_responsive() async throws {
        let mic = MicrophoneRecorder()
        mic.bringUpTimeout = 0.15
        mic.bringUpOverride = {
            // A detached task's `.value` ignores the awaiter's cancellation,
            // and Thread.sleep inside it models a wedged CoreAudio
            // dispatch_sync (won't return early for anyone).
            await Task.detached { Thread.sleep(forTimeInterval: 3.0) }.value
        }

        let started = Date()
        do {
            try await mic.start()
            XCTFail("Expected MicrophoneError.bringUpTimedOut; start() returned successfully")
        } catch let error as MicrophoneError {
            XCTAssertEqual(error, .bringUpTimedOut)
            let elapsed = Date().timeIntervalSince(started)
            // Must return near the 0.15s deadline — NOT after the 3s stall.
            // 2.0s bound = generous CI jitter margin while still strictly
            // below the stall duration.
            XCTAssertLessThan(elapsed, 2.0,
                              "start() must throw at the timeout deadline, not wait out the stalled bring-up; took \(elapsed)s")
        }
        await mic.stop()
    }

    /// The bug being prevented: even if the bring-up *thread* is wedged on
    /// CoreAudio for hundreds of milliseconds, the main thread / dispatch
    /// queue must remain free to service UI work. We assert this by parking
    /// the bring-up override in a synchronous `Thread.sleep` (which blocks
    /// whatever thread it's on) and verifying that a `DispatchQueue.main.async`
    /// block scheduled after `start()` is invoked still runs promptly.
    func test_main_thread_is_not_blocked_during_slow_bring_up() async throws {
        let mic = MicrophoneRecorder()
        mic.bringUpTimeout = 5.0
        mic.bringUpOverride = {
            // Synchronously block whatever thread runs us. If `start()` were
            // still doing CoreAudio work on the main thread (the regression
            // we're protecting against), this would freeze the UI for 0.5s
            // and our `DispatchQueue.main.async` expectation would not be
            // serviced inside the 0.2s window below.
            Thread.sleep(forTimeInterval: 0.5)
        }

        let startTask = Task { try? await mic.start() }

        let mainServiced = expectation(description: "main queue serviced while bring-up is in flight")
        DispatchQueue.main.async {
            mainServiced.fulfill()
        }
        await fulfillment(of: [mainServiced], timeout: 0.2)

        await startTask.value
        await mic.stop()
    }
}

/// Coverage for the mid-session recovery added after a user's 26-minute Zoom
/// meeting came back as 24 seconds of audio: their USB EarPods died 25s in,
/// CoreAudio re-pointed the engine's input at the built-in mic at a different
/// sample rate, and — per AVAudioEngine's documented behaviour — the engine
/// stopped itself. The tap never fired again and nothing noticed for 26
/// minutes.
final class CaptureStallDetectorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A live device delivers buffers continuously, so a growing frame count
    /// is proof capture is alive no matter how quiet the room is.
    func test_growing_frame_count_is_never_a_stall() {
        var detector = CaptureStallDetector(timeout: 4)
        XCTAssertFalse(detector.observe(frames: 0, now: t0))
        for step in 1...20 {
            let now = t0.addingTimeInterval(Double(step))
            XCTAssertFalse(detector.observe(frames: step * 1600, now: now),
                           "frames grew at step \(step) — capture is alive")
        }
    }

    func test_flatlined_frame_count_trips_after_timeout() {
        var detector = CaptureStallDetector(timeout: 4)
        XCTAssertFalse(detector.observe(frames: 16_000, now: t0))
        // Same count, but not yet long enough to call it.
        XCTAssertFalse(detector.observe(frames: 16_000, now: t0.addingTimeInterval(1)))
        XCTAssertFalse(detector.observe(frames: 16_000, now: t0.addingTimeInterval(3.9)))
        // Crossing the timeout with no growth: stalled.
        XCTAssertTrue(detector.observe(frames: 16_000, now: t0.addingTimeInterval(4.0)))
    }

    /// The stall clock must be re-armed by growth, not just by the first
    /// sample — otherwise a recording longer than `timeout` would report a
    /// stall the moment any single poll saw no new frames.
    func test_growth_rearms_the_stall_clock() {
        var detector = CaptureStallDetector(timeout: 4)
        _ = detector.observe(frames: 0, now: t0)
        XCTAssertFalse(detector.observe(frames: 100, now: t0.addingTimeInterval(3.5)))
        // 5s of total elapsed time, but only 1.5s since the last new frames.
        XCTAssertFalse(detector.observe(frames: 100, now: t0.addingTimeInterval(5.0)))
        XCTAssertTrue(detector.observe(frames: 100, now: t0.addingTimeInterval(7.5)))
    }

    /// A device that comes up but never delivers a single buffer is just as
    /// broken as one that dies mid-session, so the first observation arms the
    /// clock rather than being treated as a baseline forever.
    func test_device_that_never_delivers_a_buffer_trips() {
        var detector = CaptureStallDetector(timeout: 2)
        XCTAssertFalse(detector.observe(frames: 0, now: t0))
        XCTAssertFalse(detector.observe(frames: 0, now: t0.addingTimeInterval(1)))
        XCTAssertTrue(detector.observe(frames: 0, now: t0.addingTimeInterval(2)))
    }

    func test_reset_rearms_from_the_rebuild_not_the_last_buffer() {
        var detector = CaptureStallDetector(timeout: 2)
        _ = detector.observe(frames: 500, now: t0)
        XCTAssertTrue(detector.observe(frames: 500, now: t0.addingTimeInterval(2)))
        detector.reset()
        // Fresh baseline: the same flat count must get a full timeout again
        // before it counts as a second stall.
        XCTAssertFalse(detector.observe(frames: 500, now: t0.addingTimeInterval(2)))
        XCTAssertFalse(detector.observe(frames: 500, now: t0.addingTimeInterval(3.5)))
        XCTAssertTrue(detector.observe(frames: 500, now: t0.addingTimeInterval(4)))
    }
}

/// End-to-end wiring of the watchdog, driven through the `bringUpOverride`
/// seam: with no real tap the frame count never grows, so a stalled session is
/// exactly what the recorder sees when a device dies. Counting bring-ups tells
/// us whether it actually tried to repair capture.
@MainActor
final class MicrophoneWatchdogTests: XCTestCase {

    /// Small helper: a recorder whose bring-ups are counted, tuned to a fast
    /// watchdog so the test doesn't wait 4 real seconds per rebuild.
    private func makeRecorder(maxRestarts: Int = 60) -> (MicrophoneRecorder, @Sendable () -> Int) {
        let counter = OSAllocatedUnfairLock(initialState: 0)
        let mic = MicrophoneRecorder()
        mic.bringUpTimeout = 1.0
        mic.captureStallTimeout = 0.2
        mic.watchdogInterval = 0.05
        mic.maxMidSessionRestarts = maxRestarts
        mic.bringUpOverride = { counter.withLock { $0 += 1 } }
        return (mic, { counter.withLock { $0 } })
    }

    func test_watchdog_rebuilds_capture_when_no_buffers_arrive() async throws {
        let (mic, bringUps) = makeRecorder()
        try await mic.start()
        XCTAssertEqual(bringUps(), 1, "start() should bring the engine up exactly once")

        // Give the watchdog room for at least a couple of stall→rebuild cycles
        // (0.2s stall timeout + 0.05s poll each).
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let rebuilds = mic.restartCount
        await mic.stop()

        XCTAssertGreaterThanOrEqual(rebuilds, 1,
                                    "a session that never receives a buffer must be rebuilt, not left dead")
        XCTAssertGreaterThan(bringUps(), 1,
                             "each rebuild should re-run the bring-up; saw \(bringUps()) total")
    }

    /// The recording must not be *ended* by a rebuild: `RecordingSession` is
    /// iterating `audioStream`, so finishing that continuation would stop the
    /// recording instead of repairing it.
    func test_rebuild_keeps_the_session_audio_stream_alive() async throws {
        let (mic, _) = makeRecorder()
        try await mic.start()
        // Read the stream AFTER start(): every start() installs a fresh one so
        // leftover buffers from a previous recording can't leak into this one.
        let sessionStream = mic.audioStream

        let consumerEnded = OSAllocatedUnfairLock(initialState: false)
        let consumer = Task {
            for await _ in sessionStream {}
            consumerEnded.withLock { $0 = true }
        }

        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertGreaterThanOrEqual(mic.restartCount, 1, "expected at least one rebuild to have happened")
        XCTAssertFalse(consumerEnded.withLock { $0 },
                       "a mid-session rebuild must not finish the audio stream — that would end the recording")

        await mic.stop()
        _ = await consumer.value
        XCTAssertTrue(consumerEnded.withLock { $0 }, "stop() should finish the stream")
    }

    func test_rebuild_attempts_are_capped() async throws {
        let (mic, _) = makeRecorder(maxRestarts: 2)
        try await mic.start()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let rebuilds = mic.restartCount
        await mic.stop()
        // The cap is the assertion: given ~6 stall windows in 1.5s the
        // uncapped code would rebuild far more than twice.
        XCTAssertGreaterThanOrEqual(rebuilds, 1, "expected the watchdog to have fired at all")
        XCTAssertLessThanOrEqual(rebuilds, 2,
                                 "a permanently dead input must stop being retried at the cap, not forever")
    }

    func test_stop_cancels_the_watchdog() async throws {
        let (mic, bringUps) = makeRecorder()
        try await mic.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        await mic.stop()

        let afterStop = bringUps()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(bringUps(), afterStop,
                       "no bring-ups may happen after stop() — the watchdog must be cancelled")
    }
}
