import XCTest
@testable import Mila

/// Pins the empty-transcript placeholder decision in `RecordingDetailView`.
/// The regression this guards: a recording queued behind the active
/// transcription used to show "Click … Transcribe to start" while that very
/// menu was disabled (`busy` in `actionButtons`), sending the user to a
/// dead-end control.
final class RecordingDetailPlaceholderTests: XCTestCase {

    func test_queued_recording_shows_waiting_not_click_transcribe() {
        XCTAssertEqual(
            RecordingDetailView.emptyTranscriptPlaceholder(isActive: false, isQueued: true),
            .waitingInQueue,
            "A queued recording's Transcribe menu is disabled — the placeholder must not tell the user to click it."
        )
    }

    func test_idle_recording_invites_transcription() {
        XCTAssertEqual(
            RecordingDetailView.emptyTranscriptPlaceholder(isActive: false, isQueued: false),
            .clickTranscribe,
            "With nothing queued the Transcribe menu is enabled, so the click-to-start instruction is actionable."
        )
    }

    func test_active_recording_has_no_placeholder() {
        XCTAssertNil(
            RecordingDetailView.emptyTranscriptPlaceholder(isActive: true, isQueued: false),
            "While actively transcribing, the progress view owns the transcript area — no placeholder."
        )
    }

    func test_active_wins_over_queued() {
        XCTAssertNil(
            RecordingDetailView.emptyTranscriptPlaceholder(isActive: true, isQueued: true),
            "An id can transiently be both active and pending; the progress view must win."
        )
    }

    /// A recording whose transcription the user stopped is stored `.failed`;
    /// the placeholder has to say "stopped", not leave them guessing.
    func test_stopped_recording_says_stopped() {
        XCTAssertEqual(
            RecordingDetailView.emptyTranscriptPlaceholder(isActive: false, isQueued: false, isDeferred: true),
            .stopped
        )
    }

    /// Transcribe was clicked again: the marker is cleared as the row is
    /// queued, but the queue state must win even if the view sees both for a
    /// frame.
    func test_queued_wins_over_stopped() {
        XCTAssertEqual(
            RecordingDetailView.emptyTranscriptPlaceholder(isActive: false, isQueued: true, isDeferred: true),
            .waitingInQueue
        )
    }

    /// #376: a failed transcription used to show "No transcript yet" with
    /// nothing saying it had failed, let alone why.
    func test_failed_recording_says_why() {
        XCTAssertEqual(
            RecordingDetailView.emptyTranscriptPlaceholder(
                isActive: false, isQueued: false,
                failureReason: "Remote server returned HTTP 400."),
            .failed(reason: "Remote server returned HTTP 400.", canRetry: true)
        )
    }

    /// Missing or unusable audio fails the same way on every retry, so the
    /// placeholder must not send the user to Transcribe for it.
    func test_a_failure_of_the_audio_itself_offers_no_retry() {
        for reason in [Recording.missingAudioFailureReason, Recording.unusableAudioFailureReason] {
            XCTAssertEqual(
                RecordingDetailView.emptyTranscriptPlaceholder(isActive: false, isQueued: false,
                                                               failureReason: reason),
                .failed(reason: reason, canRetry: false)
            )
        }
    }

    /// A retry is queued: the old failure no longer describes the row.
    func test_queued_and_active_win_over_failed() {
        XCTAssertEqual(
            RecordingDetailView.emptyTranscriptPlaceholder(isActive: false, isQueued: true,
                                                           failureReason: "refused"),
            .waitingInQueue
        )
        XCTAssertNil(
            RecordingDetailView.emptyTranscriptPlaceholder(isActive: true, isQueued: false,
                                                           failureReason: "refused")
        )
    }

    /// A stopped run says stopped, whatever an earlier run's failure said.
    func test_stopped_wins_over_failed() {
        XCTAssertEqual(
            RecordingDetailView.emptyTranscriptPlaceholder(isActive: false, isQueued: false,
                                                           isDeferred: true, failureReason: "refused"),
            .stopped
        )
    }
}
