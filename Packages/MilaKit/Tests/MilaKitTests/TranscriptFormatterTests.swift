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

    /// `seconds` comes out of a user-editable file, and this runs inside the
    /// long-lived mila-mcp process, where `Int(_:)` trapping on one bad row
    /// would take the server down. Garbage pins to the nearest end of what
    /// SRT's HH:MM:SS,mmm field can hold instead of trapping, printing a
    /// negative field, or overflowing the two-digit hour.
    func test_srt_timestamp_pins_unrepresentable_values_instead_of_trapping() {
        XCTAssertEqual(TranscriptFormatter.srtTimestamp(.nan), "00:00:00,000")
        XCTAssertEqual(TranscriptFormatter.srtTimestamp(-0.6), "00:00:00,000")
        XCTAssertEqual(TranscriptFormatter.srtTimestamp(-.infinity), "00:00:00,000")
        XCTAssertEqual(TranscriptFormatter.srtTimestamp(.infinity), "99:59:59,999")
        XCTAssertEqual(TranscriptFormatter.srtTimestamp(1e19), "99:59:59,999")
        XCTAssertEqual(TranscriptFormatter.srtTimestamp(360_000), "99:59:59,999",
                       "100 hours does not fit the field either")
        XCTAssertEqual(TranscriptFormatter.srtTimestamp(359_999.999), "99:59:59,999",
                       "the last representable value itself is rendered as-is")
        let body = TranscriptFormatter.srt(segments: [TimedSeg(start: .nan, end: 1e300, text: "x")])
        XCTAssertEqual(body, "1\n00:00:00,000 --> 99:59:59,999\nx\n\n")
    }

    /// The handler drops cues to honour `max_chars` and reassembles the rest
    /// through `srt(cues:)`; that must produce the same bytes `srt(segments:)`
    /// would, so the two paths cannot drift.
    func test_srt_cues_reassemble_to_the_same_bytes_as_srt() {
        let segments = [TimedSeg(start: 0, end: 1, text: "a"), TimedSeg(start: 1, end: 2, text: "b")]
        let cues = TranscriptFormatter.srtCues(segments: segments)
        XCTAssertEqual(TranscriptFormatter.srt(cues: cues), TranscriptFormatter.srt(segments: segments))
        XCTAssertEqual(TranscriptFormatter.srt(cues: Array(cues.prefix(1))), cues[0] + "\n\n")
        XCTAssertEqual(TranscriptFormatter.srt(cues: []), "")
    }

    /// A blank line is SRT's only cue delimiter, so a segment whose text
    /// carried one read back as two cues — the second without a number or
    /// timing. Interior blank lines (empty or whitespace-only, `\n` or
    /// `\r\n`) collapse so one segment stays one cue; a lone line break is a
    /// legal two-line cue and stays; the outer trim is unchanged.
    func test_srt_keeps_one_segment_one_cue_when_the_text_carries_a_blank_line() {
        let segments = [
            TimedSeg(start: 0, end: 1, text: "first line\n\nsecond line", speaker: "SPEAKER_00"),
            TimedSeg(start: 1, end: 2, text: "a\n \n\t\nb\r\n\r\nc"),
            TimedSeg(start: 2, end: 3, text: "two\nlines"),
            TimedSeg(start: 3, end: 4, text: "  padded  "),
        ]
        let cues = TranscriptFormatter.srtCues(segments: segments)
        XCTAssertEqual(cues, [
            "1\n00:00:00,000 --> 00:00:01,000\nSPEAKER_00: first line\nsecond line",
            "2\n00:00:01,000 --> 00:00:02,000\na\nb\nc",
            "3\n00:00:02,000 --> 00:00:03,000\ntwo\nlines",
            "4\n00:00:03,000 --> 00:00:04,000\npadded",
        ])
        // The read-back statement of the same thing: a parser splitting the
        // file on blank lines finds exactly one block per segment.
        let blocks = TranscriptFormatter.srt(segments: segments)
            .components(separatedBy: "\n\n").filter { !$0.isEmpty }
        XCTAssertEqual(blocks.count, segments.count)
    }

    /// Text with no line break in it must come back unchanged: that is the
    /// guarantee that the app's `.srt` export (every whisper segment is one
    /// line) did not change. The other cases pin how breaks are rejoined.
    func test_cue_text_without_a_line_break_is_returned_untouched() {
        let plain = "no breaks here,  just   spacing "
        XCTAssertEqual(TranscriptFormatter.cueText(plain), plain)
        XCTAssertEqual(TranscriptFormatter.cueText("x\n\n\ny"), "x\ny")
        XCTAssertEqual(TranscriptFormatter.cueText("x\r\ny"), "x\ny", "CRLF rejoins with the file's own separator")
        XCTAssertEqual(TranscriptFormatter.cueText("x\n  \ny"), "x\ny", "a whitespace-only line is blank to a lenient parser")
        XCTAssertEqual(TranscriptFormatter.cueText("keep  \n  inner"), "keep  \n  inner",
                       "surviving lines keep their own bytes")
        XCTAssertEqual(TranscriptFormatter.cueText("a\u{2028}\u{2028}b"), "a\nb",
                       "a generic line splitter breaks on U+2028 too")
        XCTAssertEqual(TranscriptFormatter.cueText("a\u{2029}b"), "a\nb")
    }
}

private struct TimedSeg: TimedSpeakerTextSegment {
    var start: Double
    var end: Double
    var text: String
    var speaker: String? = nil
}
