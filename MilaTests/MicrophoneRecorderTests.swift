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

/// Policy coverage for the rebuild pacing added after issue #147: binding the
/// input device during bring-up made the engine post
/// `AVAudioEngineConfigurationChange` on the reporter's Mac, the handler
/// rebuilt immediately, the rebuild re-bound the device, and the whole thing
/// went round at ~150ms — ~7 microphone start/stop cycles per second, with the
/// tap never alive long enough to deliver one buffer.
///
/// `maxMidSessionRestarts = 60` did not save it: its "60 attempts at ≥1s
/// apart" comment described the watchdog's cadence, and the notification path
/// had no cadence at all, so the whole budget burned in about nine seconds.
final class RebuildThrottleTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    /// The first configuration change of a session is always acted on
    /// immediately — pacing must not make a genuine device swap feel broken.
    func test_first_rebuild_is_immediate() {
        var throttle = RebuildThrottle(minimumInterval: 1, maximumInterval: 30)
        XCTAssertEqual(throttle.currentInterval, 0)
        XCTAssertTrue(throttle.allow(now: t0))
    }

    /// The regression, stated as policy: a burst of notifications at the
    /// observed ~150ms cadence must collapse to a single rebuild.
    func test_a_storm_of_changes_collapses_to_one_rebuild() {
        var throttle = RebuildThrottle(minimumInterval: 1, maximumInterval: 30)
        var allowed = 0
        for step in 0..<60 {                       // 9 seconds at 150ms
            if throttle.allow(now: t0.addingTimeInterval(Double(step) * 0.15)) { allowed += 1 }
        }
        // 9 seconds spans the 1s floor and then the 2s and 4s backoff steps.
        XCTAssertLessThanOrEqual(allowed, 4,
                                 "60 changes in 9s must not mean 60 rebuilds; allowed \(allowed)")
        XCTAssertGreaterThanOrEqual(allowed, 1, "the first change must still be acted on")
    }

    /// Documents the behaviour being replaced: with no minimum interval, every
    /// single notification is a rebuild. This is what shipped in 1.9.2-beta.2.
    func test_without_a_minimum_interval_every_change_rebuilds() {
        var throttle = RebuildThrottle(minimumInterval: 0, maximumInterval: 0)
        var allowed = 0
        for step in 0..<60 {
            if throttle.allow(now: t0.addingTimeInterval(Double(step) * 0.15)) { allowed += 1 }
        }
        XCTAssertEqual(allowed, 60)
    }

    func test_backoff_doubles_and_saturates_at_the_ceiling() {
        var throttle = RebuildThrottle(minimumInterval: 1, maximumInterval: 8)
        var now = t0
        var intervals: [TimeInterval] = []
        for _ in 0..<6 {
            XCTAssertTrue(throttle.allow(now: now))
            intervals.append(throttle.currentInterval)
            // Advance exactly to the next permitted moment.
            now = now.addingTimeInterval(throttle.currentInterval)
        }
        XCTAssertEqual(intervals, [1, 2, 4, 8, 8, 8])
    }

    /// The budget has to span minutes, which was the whole claim of the
    /// `maxMidSessionRestarts` comment. Walk the ladder for the real defaults.
    func test_the_rebuild_budget_spans_minutes_not_seconds() {
        var throttle = RebuildThrottle(minimumInterval: 1, maximumInterval: 30)
        var now = t0
        for _ in 0..<60 {
            XCTAssertTrue(throttle.allow(now: now))
            now = now.addingTimeInterval(throttle.currentInterval)
        }
        let spanned = now.timeIntervalSince(t0)
        XCTAssertGreaterThan(spanned, 20 * 60,
                             "60 notification-driven rebuilds should span many minutes, not the ~9s of the bug; spanned \(spanned)s")
    }

    /// Backoff must not punish an unrelated event much later in a long
    /// meeting: a quiet spell means the burst is over.
    func test_a_quiet_spell_resets_the_backoff() {
        var throttle = RebuildThrottle(minimumInterval: 1, maximumInterval: 10)
        XCTAssertTrue(throttle.allow(now: t0))
        XCTAssertTrue(throttle.allow(now: t0.addingTimeInterval(1)))
        XCTAssertEqual(throttle.currentInterval, 2)
        // 10 minutes later, the user unplugs their headphones.
        XCTAssertTrue(throttle.allow(now: t0.addingTimeInterval(600)))
        XCTAssertEqual(throttle.currentInterval, 1, "the ladder should start over after a quiet spell")
    }

    /// The subtle one, and a real bug caught by CI on the first push: a burst
    /// that has saturated the backoff arrives *exactly* `maximumInterval`
    /// apart. If that counted as a quiet spell, the ladder would reset on
    /// every tick and the effective floor would collapse back to
    /// `minimumInterval` — the unpaced behaviour, reintroduced one level up.
    func test_pacing_exactly_at_the_ceiling_is_not_a_quiet_spell() {
        var throttle = RebuildThrottle(minimumInterval: 1, maximumInterval: 8)
        var now = t0
        for _ in 0..<8 {
            XCTAssertTrue(throttle.allow(now: now))
            now = now.addingTimeInterval(throttle.currentInterval)
        }
        XCTAssertEqual(throttle.currentInterval, 8,
                       "a burst pacing itself at the ceiling must stay at the ceiling")
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

/// The configuration-change path, driven through the REAL observer.
///
/// Issue #147: on the reporter's Mac, `bringUp()`'s own
/// `kAudioOutputUnitProperty_CurrentDevice` bind made AVAudioEngine post
/// `AVAudioEngineConfigurationChange`; the handler rebuilt at once, the
/// rebuild re-bound the device, and the loop sustained itself at ~150ms until
/// the user hit Stop — `buffers=0 frames=0 rebuilds=13`, a header-only WAV,
/// and an `HTTP 500: Failed to decode audio.` that looked like a server
/// outage.
///
/// Why these tests can run on a headless CI runner with no microphone: the
/// recorder registers its observer against `configurationChangeSource` — the
/// live `AVAudioEngine` in production, a stand-in object on the
/// `bringUpOverride` path. Everything under test is real (the observer, the
/// notification name, the handler, the grace window, the throttle, the rebuild
/// budget); only the *poster* of the notification is simulated, which is
/// exactly the part CoreAudio would otherwise have to provide.
///
/// The watchdog is parked (`captureStallTimeout` far beyond the test's
/// lifetime) in every test here so the only thing that can rebuild capture is
/// the notification path being measured.
@MainActor
final class MicrophoneConfigurationChangeTests: XCTestCase {

    /// `grace` is per-test on purpose. The handler timestamps a notification
    /// when it RUNS, not when it was posted, so a test that wants a change
    /// treated as self-inflicted needs a window comfortably longer than any
    /// plausible main-actor hop on a loaded runner, while a test that wants it
    /// treated as real needs a short one it can wait out. Neither number is a
    /// production value; the shipped default is 0.75s.
    private func makeRecorder(grace: TimeInterval) -> (MicrophoneRecorder, @Sendable () -> Int) {
        let counter = OSAllocatedUnfairLock(initialState: 0)
        let mic = MicrophoneRecorder()
        mic.bringUpTimeout = 1.0
        // Park the stall watchdog: it has its own tests, and here it would be
        // a second source of rebuilds.
        mic.captureStallTimeout = 3600
        mic.watchdogInterval = 3600
        mic.configurationChangeGracePeriod = grace
        mic.minimumRebuildInterval = 1.0
        mic.maximumRebuildInterval = 4.0
        mic.bringUpOverride = { counter.withLock { $0 += 1 } }
        return (mic, { counter.withLock { $0 } })
    }

    /// Poll until `condition` holds or `timeout` elapses. Lets a slow runner
    /// take longer without letting it change the verdict — the assertions that
    /// follow still have to hold exactly.
    private func waitUntil(_ timeout: TimeInterval = 3.0,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func postConfigurationChange(to mic: MicrophoneRecorder) {
        // Re-read the source every time: production installs a brand-new
        // engine on each rebuild, and it is the new engine that posts the next
        // change. Posting to a stale source would make the loop untestable —
        // the second notification would simply go nowhere.
        guard let source = mic.configurationChangeSource else {
            return XCTFail("recorder registered no configuration-change source")
        }
        NotificationCenter.default.post(
            name: NSNotification.Name.AVAudioEngineConfigurationChange,
            object: source)
    }

    /// Fix (1): the notification our own device bind provokes must not be
    /// mistaken for the world changing.
    func test_self_inflicted_change_during_bring_up_does_not_rebuild() async throws {
        let (mic, bringUps) = makeRecorder(grace: 1.0)
        try await mic.start()
        XCTAssertEqual(bringUps(), 1)

        // Same instant as the bring-up — this is what the bind itself posts.
        postConfigurationChange(to: mic)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(mic.restartCount, 0,
                       "a configuration change inside the bring-up grace window is our own doing — rebuilding it is what started the loop")
        XCTAssertEqual(bringUps(), 1, "the engine must not have been torn down and rebuilt")
        await mic.stop()
    }

    /// The counterweight to the test above, and the risk the grace window
    /// carries: suppressing self-inflicted changes must NOT blind the recorder
    /// to a device that genuinely went away.
    func test_change_after_the_grace_window_still_rebuilds() async throws {
        let (mic, bringUps) = makeRecorder(grace: 0.1)
        try await mic.start()
        try await Task.sleep(nanoseconds: 400_000_000)   // past the 0.1s window

        postConfigurationChange(to: mic)
        await waitUntil { mic.restartCount >= 1 }

        XCTAssertEqual(mic.restartCount, 1,
                       "a real device change must still be repaired promptly, and exactly once")
        XCTAssertEqual(bringUps(), 2)
        await mic.stop()
    }

    /// Fix (2), and the shape of the actual bug: a *storm* of changes — each
    /// one provoked by the rebuild that answered the last — must be bounded.
    ///
    /// Before the fix this produced one rebuild per notification: the
    /// reporter's log shows 13 rebuilds in the ~2s before they hit Stop, and
    /// the 60-rebuild budget would have been gone in nine seconds.
    func test_a_storm_of_configuration_changes_is_bounded() async throws {
        // Short grace window on purpose: what's under test here is the
        // throttle, not the self-inflicted-change suppression.
        let (mic, bringUps) = makeRecorder(grace: 0.1)
        try await mic.start()
        try await Task.sleep(nanoseconds: 400_000_000)   // past the grace window

        // Post continuously for a fixed WALL-CLOCK window at roughly the
        // cadence observed in the bug (~150ms, compressed to 15ms here).
        // Wall-clock rather than a fixed iteration count so a slow CI runner
        // stretches the number of posts, not the window the policy is judged
        // over.
        var posts = 0
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            postConfigurationChange(to: mic)
            posts += 1
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertGreaterThan(posts, 10, "the burst should have delivered plenty of notifications")
        // Floor is 1s and the burst is 0.6s, so one rebuild is the expected
        // answer; the bound is 2 purely for CI clock jitter. The point is that
        // the count tracks the POLICY, not the number of notifications.
        XCTAssertLessThanOrEqual(mic.restartCount, 2,
                                 "\(posts) configuration changes in 0.6s produced \(mic.restartCount) rebuilds — the notification path is not paced")
        XCTAssertLessThanOrEqual(bringUps(), 3)
        await mic.stop()
    }

    /// A rebuild storm must not be able to outlive the recording either.
    func test_configuration_change_after_stop_is_ignored() async throws {
        let (mic, bringUps) = makeRecorder(grace: 0.1)
        try await mic.start()
        let source = mic.configurationChangeSource
        try await Task.sleep(nanoseconds: 400_000_000)
        await mic.stop()

        if let source {
            NotificationCenter.default.post(
                name: NSNotification.Name.AVAudioEngineConfigurationChange,
                object: source)
        }
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(mic.restartCount, 0)
        XCTAssertEqual(bringUps(), 1, "no bring-up may happen after stop()")
    }
}
