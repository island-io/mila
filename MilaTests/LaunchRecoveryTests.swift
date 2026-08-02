import XCTest
@testable import Mila

/// Unit tests for the launch crash-recovery decision (`MilaApp.recoveryAction`),
/// the pure core of `enqueueRecoveredRecordings`.
///
/// REGRESSION: the sweep used to only resurrect `.running` recordings, so a
/// recording persisted as `.pending` (queued but never started before the app
/// quit) was never re-enqueued on the next launch — it sat in the Queue forever
/// showing "Queued". `.pending` must be recovered exactly like `.running`.
final class LaunchRecoveryTests: XCTestCase {

    // MARK: - .pending is recovered (the regression)

    func test_pending_with_audio_is_reenqueued() {
        XCTAssertEqual(
            MilaApp.recoveryAction(status: .pending, wavExists: true),
            .reenqueue,
            "A .pending recording whose WAV survives must be re-enqueued at launch, not stranded in the Queue."
        )
    }

    func test_pending_without_audio_is_failed() {
        XCTAssertEqual(
            MilaApp.recoveryAction(status: .pending, wavExists: false),
            .markFailed,
            "A .pending recording whose WAV is gone can't be recovered — mark it .failed so it stops retrying."
        )
    }

    // MARK: - .running keeps its existing behavior

    func test_running_with_audio_is_reenqueued() {
        XCTAssertEqual(MilaApp.recoveryAction(status: .running, wavExists: true), .reenqueue)
    }

    func test_running_without_audio_is_failed() {
        XCTAssertEqual(MilaApp.recoveryAction(status: .running, wavExists: false), .markFailed)
    }

    // MARK: - Terminal states are never touched

    func test_completed_is_left_alone_regardless_of_audio() {
        XCTAssertEqual(MilaApp.recoveryAction(status: .completed, wavExists: true), .leaveAlone)
        XCTAssertEqual(MilaApp.recoveryAction(status: .completed, wavExists: false), .leaveAlone)
    }

    func test_failed_is_left_alone_regardless_of_audio() {
        XCTAssertEqual(MilaApp.recoveryAction(status: .failed, wavExists: true), .leaveAlone)
        XCTAssertEqual(MilaApp.recoveryAction(status: .failed, wavExists: false), .leaveAlone)
    }
}
