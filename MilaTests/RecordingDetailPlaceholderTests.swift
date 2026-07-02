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
}
