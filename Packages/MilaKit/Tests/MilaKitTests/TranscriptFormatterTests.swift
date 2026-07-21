import XCTest
@testable import MilaKit

private struct Seg: SpeakerTextSegment {
    var text: String
    var speaker: String?
}

final class MilaKitTranscriptFormatterTests: XCTestCase {

    func test_no_speakers_returns_fallback() {
        let segments = [Seg(text: "hello", speaker: nil), Seg(text: "world", speaker: nil)]
        XCTAssertEqual(TranscriptFormatter.plainText(segments: segments, fallback: "hello world"),
                       "hello world")
    }

    func test_speaker_turns_collapse_and_prefix() {
        let segments = [
            Seg(text: "hi", speaker: "SPEAKER_00"),
            Seg(text: "there", speaker: "SPEAKER_00"),
            Seg(text: "hey", speaker: "SPEAKER_01"),
        ]
        XCTAssertEqual(TranscriptFormatter.plainText(segments: segments, fallback: ""),
                       "SPEAKER_00: hi there\nSPEAKER_01: hey")
    }

    func test_names_resolve_and_merge_identically_named_ids() {
        let segments = [
            Seg(text: "one", speaker: "SPEAKER_00"),
            Seg(text: "two", speaker: "SPEAKER_01"),
        ]
        let names = ["SPEAKER_00": "Dana", "SPEAKER_01": "Dana"]
        XCTAssertEqual(TranscriptFormatter.plainText(segments: segments, fallback: "", names: names),
                       "Dana: one two")
    }

    func test_empty_segments_skipped_and_unlabeled_segment_kept_bare() {
        let segments = [
            Seg(text: "  ", speaker: "SPEAKER_00"),
            Seg(text: "spoken", speaker: "SPEAKER_00"),
            Seg(text: "aside", speaker: nil),
        ]
        XCTAssertEqual(TranscriptFormatter.plainText(segments: segments, fallback: ""),
                       "SPEAKER_00: spoken\naside")
    }
}
