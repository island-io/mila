import XCTest
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
