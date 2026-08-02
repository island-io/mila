import XCTest
import SwiftUI
import TranscriptionCore
@testable import Mila

final class SpeakerColorTests: XCTestCase {

    func test_same_speaker_id_always_gets_the_same_color() {
        XCTAssertEqual("SPEAKER_00".speakerColor, "SPEAKER_00".speakerColor)
        XCTAssertEqual("SPEAKER_03".speakerColor, "SPEAKER_03".speakerColor)
    }

    func test_different_speakers_get_different_colors() {
        XCTAssertNotEqual("SPEAKER_00".speakerColor, "SPEAKER_01".speakerColor)
        XCTAssertNotEqual("SPEAKER_00".speakerColor, "SPEAKER_02".speakerColor)
        XCTAssertNotEqual("SPEAKER_01".speakerColor, "SPEAKER_02".speakerColor)
    }

    func test_color_wraps_around_the_palette_beyond_its_size() {
        // Whatever the palette size N is, speaker N should reuse speaker 0's
        // color rather than crash or silently default to one color.
        let first = "SPEAKER_00".speakerColor
        let wrapped = (1..<64).contains { index in
            "SPEAKER_\(String(format: "%02d", index))".speakerColor == first
        }
        XCTAssertTrue(wrapped, "Palette should wrap back to speaker 0's color well before 64 distinct speakers.")
    }

    func test_non_standard_speaker_ids_still_resolve_to_a_stable_color() {
        XCTAssertEqual("host".speakerColor, "host".speakerColor)
        XCTAssertEqual("Alice".speakerColor, "Alice".speakerColor)
    }

    // MARK: - hasMultipleSpeakers

    private func transcriptSegment(speaker: String?) -> TranscriptSegment {
        TranscriptSegment(start: 0, end: 1, text: "", speaker: speaker)
    }

    private func liveSegment(speaker: String?) -> LiveSegment {
        LiveSegment(id: UUID(), startSeconds: 0, endSeconds: 1, text: "", speaker: speaker, stable: true)
    }

    func test_hasMultipleSpeakers_false_when_zero_or_one_distinct_speaker() {
        XCTAssertFalse([TranscriptSegment]().hasMultipleSpeakers)
        XCTAssertFalse([transcriptSegment(speaker: nil), transcriptSegment(speaker: nil)].hasMultipleSpeakers)
        XCTAssertFalse([transcriptSegment(speaker: "SPEAKER_00"), transcriptSegment(speaker: "SPEAKER_00")].hasMultipleSpeakers)
    }

    func test_hasMultipleSpeakers_true_once_a_second_distinct_speaker_appears() {
        let segments = [
            transcriptSegment(speaker: "SPEAKER_00"),
            transcriptSegment(speaker: nil),
            transcriptSegment(speaker: "SPEAKER_01"),
        ]
        XCTAssertTrue(segments.hasMultipleSpeakers)
    }

    func test_hasMultipleSpeakers_works_for_live_segments_too() {
        XCTAssertFalse([liveSegment(speaker: "SPEAKER_00")].hasMultipleSpeakers)
        XCTAssertTrue([liveSegment(speaker: "SPEAKER_00"), liveSegment(speaker: "SPEAKER_01")].hasMultipleSpeakers)
    }
}
