import XCTest
@testable import Mila

/// When ScreenCaptureKit kills the stream from its own side mid-recording, the
/// meeting silently loses the *other side of the conversation* — the user's own
/// mic keeps working, so nothing looks wrong until they read the transcript.
/// Previously the only reaction was setting `lastStreamError` (and a `print`
/// that never reached OSLog, so diagnostic bundles showed no trace of it).
/// Now the recorder tries to get the leg back; these cover when it should and
/// shouldn't.
final class SystemAudioRestartPolicyTests: XCTestCase {

    private let genericError = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
                                      code: -3808,
                                      userInfo: [NSLocalizedDescriptionKey: "stream stopped"])

    /// SCK code -3801 is `userDeclined`.
    private let permissionError = NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
                                         code: -3801,
                                         userInfo: [NSLocalizedDescriptionKey: "user declined"])

    func test_transient_stream_death_mid_recording_is_retried() {
        XCTAssertEqual(SystemAudioRecorder.restartDecision(wantsCapture: true,
                                                          attemptsSoFar: 0,
                                                          maxAttempts: 5,
                                                          error: genericError),
                       .retry)
    }

    /// A stream that dies *because the user pressed stop* must not be revived —
    /// that would leave a hot SCStream running after the recording ended.
    func test_stream_death_after_stop_is_not_retried() {
        XCTAssertEqual(SystemAudioRecorder.restartDecision(wantsCapture: false,
                                                          attemptsSoFar: 0,
                                                          maxAttempts: 5,
                                                          error: genericError),
                       .sessionOver)
    }

    func test_permission_failures_are_not_retried() {
        XCTAssertEqual(SystemAudioRecorder.restartDecision(wantsCapture: true,
                                                          attemptsSoFar: 0,
                                                          maxAttempts: 5,
                                                          error: permissionError),
                       .permissionDenied)
    }

    /// Permission is checked before the budget: a revoked grant should say so
    /// plainly rather than reporting an exhausted retry budget.
    func test_permission_check_precedes_the_retry_budget() {
        XCTAssertEqual(SystemAudioRecorder.restartDecision(wantsCapture: true,
                                                          attemptsSoFar: 99,
                                                          maxAttempts: 5,
                                                          error: permissionError),
                       .permissionDenied)
    }

    func test_retries_are_bounded() {
        XCTAssertEqual(SystemAudioRecorder.restartDecision(wantsCapture: true,
                                                          attemptsSoFar: 4,
                                                          maxAttempts: 5,
                                                          error: genericError),
                       .retry)
        XCTAssertEqual(SystemAudioRecorder.restartDecision(wantsCapture: true,
                                                          attemptsSoFar: 5,
                                                          maxAttempts: 5,
                                                          error: genericError),
                       .budgetExhausted)
    }
}
