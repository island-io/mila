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

    // MARK: - SRT
    //
    // The SRT renderer moved here from the app's `TranscriptExporter` so the
    // MCP helper can serve the same bytes. `MilaTests/TranscriptExporterTests`
    // still pins the format from the app side; these pin it from the package
    // side, where `mila-mcp` builds without the app.

    func test_srt_emits_one_numbered_cue_per_non_blank_segment() {
        let segments = [
            TimedSeg(start: 0, end: 1.2, text: "Hello"),
            TimedSeg(start: 1.2, end: 2.4, text: "   "),
            TimedSeg(start: 2.4, end: 3.6, text: "World"),
        ]
        let body = TranscriptFormatter.srt(segments: segments)
        XCTAssertEqual(body,
                       "1\n00:00:00,000 --> 00:00:01,200\nHello\n\n"
                       + "2\n00:00:02,400 --> 00:00:03,600\nWorld\n\n",
                       "blank segment skipped, numbering stays sequential, trailing blank line kept")
    }

    func test_srt_uses_assigned_names_with_raw_id_fallback_and_never_collapses_turns() {
        let segments = [
            TimedSeg(start: 0, end: 1, text: "Hi", speaker: "SPEAKER_00"),
            TimedSeg(start: 1, end: 2, text: "again", speaker: "SPEAKER_00"),
            TimedSeg(start: 2, end: 3, text: "Hello", speaker: "SPEAKER_01"),
        ]
        let cues = TranscriptFormatter.srtCues(segments: segments, names: ["SPEAKER_00": "Daniel"])
        XCTAssertEqual(cues.count, 3, "same-speaker segments keep their own cue (unlike plainText)")
        XCTAssertEqual(cues[0], "1\n00:00:00,000 --> 00:00:01,000\nDaniel: Hi")
        XCTAssertEqual(cues[1], "2\n00:00:01,000 --> 00:00:02,000\nDaniel: again")
        XCTAssertEqual(cues[2], "3\n00:00:02,000 --> 00:00:03,000\nSPEAKER_01: Hello")
    }

    func test_srt_timestamp_uses_comma_decimal_separator() {
        XCTAssertEqual(TranscriptFormatter.srtTimestamp(1.5), "00:00:01,500")
        XCTAssertEqual(TranscriptFormatter.srtTimestamp(3725.042), "01:02:05,042")
    }

    /// Rounding to whole milliseconds must happen BEFORE the h/m/s split:
    /// a value within 0.5 ms below a minute boundary used to print an
    /// invalid `:60` seconds field.
    func test_srt_timestamp_rounds_up_across_minute_and_hour_boundaries() {
        XCTAssertEqual(TranscriptFormatter.srtTimestamp(59.9996), "00:01:00,000")
        XCTAssertEqual(TranscriptFormatter.srtTimestamp(3599.9996), "01:00:00,000")
        let body = TranscriptFormatter.srt(segments: [TimedSeg(start: 59.9996, end: 3599.9996, text: "x")])
        XCTAssertFalse(body.contains(":60,"), body)
    }

    func test_srt_is_empty_when_there_is_nothing_to_write() {
        XCTAssertEqual(TranscriptFormatter.srt(segments: [TimedSeg]()), "")
        XCTAssertEqual(TranscriptFormatter.srt(segments: [TimedSeg(start: 0, end: 1, text: " \n ")]), "")
        XCTAssertTrue(TranscriptFormatter.srtCues(segments: [TimedSeg(start: 0, end: 1, text: "")]).isEmpty)
    }
}

private struct TimedSeg: TimedSpeakerTextSegment {
    var start: Double
    var end: Double
    var text: String
    var speaker: String? = nil
}
