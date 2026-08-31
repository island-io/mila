import XCTest
@testable import MilaKit

/// The live-transcript poll cursor is append-only by construction:
/// `next_segment_index` is a count and `segments(sinceIndex:)` returns from
/// one before it, so the only change it can describe is "more lines, and the
/// last one you saw may have been rewritten". Once the user can DELETE a line
/// from the live pane (issue for PR #125), that stops covering everything —
/// nothing in a delta can say "the line you already hold is gone".
///
/// `segmentsWereRemoved(from:to:)` is what tells the two apart, and it has to
/// be precise in BOTH directions:
///
///   * miss a real removal and a poller keeps the deleted line for the rest of
///     the meeting, with its cursor off by one so every later line is
///     mis-stitched too;
///   * cry removal on an ordinary tick and every poll of a multi-speaker
///     meeting turns into a full resend, because live diarization keeps
///     labelling already-published lines.
final class LiveTranscriptRemovalTests: XCTestCase {

    private typealias Segment = LiveTranscriptSnapshot.Segment

    private func seg(_ start: Double, _ text: String, speaker: String? = nil) -> Segment {
        Segment(start: start, end: start + 1, text: text, speaker: speaker)
    }

    // MARK: - Removals that must be reported

    func test_dropping_a_middle_line_is_a_removal() {
        let before = [seg(0, "alpha"), seg(1, "beta"), seg(2, "gamma")]
        let after = [seg(0, "alpha"), seg(2, "gamma")]
        XCTAssertTrue(LiveTranscriptSnapshot.segmentsWereRemoved(from: before, to: after))
    }

    func test_dropping_a_middle_line_while_a_new_one_arrives_is_still_a_removal() {
        // Same count on both sides — the give-away is that the protected
        // prefix shifted, not that the list got shorter. A count-only check
        // would call this an ordinary tick and leak "beta".
        let before = [seg(0, "alpha"), seg(1, "beta"), seg(2, "gamma")]
        let after = [seg(0, "alpha"), seg(2, "gamma"), seg(3, "delta")]
        XCTAssertTrue(LiveTranscriptSnapshot.segmentsWereRemoved(from: before, to: after))
    }

    func test_dropping_the_only_line_is_a_removal() {
        XCTAssertTrue(LiveTranscriptSnapshot.segmentsWereRemoved(from: [seg(0, "alpha")], to: []))
    }

    func test_dropping_the_first_of_two_lines_is_a_removal() {
        XCTAssertTrue(LiveTranscriptSnapshot.segmentsWereRemoved(
            from: [seg(0, "alpha"), seg(1, "beta")], to: [seg(1, "beta")]))
    }

    /// Same text, different timing: whisper re-emitting an earlier utterance
    /// at a shifted position means the client's index no longer names the same
    /// line, which is the thing the cursor cannot survive.
    func test_a_retimed_prefix_line_is_a_removal() {
        let before = [seg(0, "alpha"), seg(1, "beta"), seg(2, "gamma")]
        var after = before
        after[0] = Segment(start: 9, end: 10, text: "alpha")
        XCTAssertTrue(LiveTranscriptSnapshot.segmentsWereRemoved(from: before, to: after))
    }

    // MARK: - Ordinary ticks that must NOT be reported

    func test_appending_is_not_a_removal() {
        let before = [seg(0, "alpha"), seg(1, "beta")]
        let after = before + [seg(2, "gamma")]
        XCTAssertFalse(LiveTranscriptSnapshot.segmentsWereRemoved(from: before, to: after))
    }

    func test_first_content_tick_is_not_a_removal() {
        XCTAssertFalse(LiveTranscriptSnapshot.segmentsWereRemoved(from: [], to: [seg(0, "alpha")]))
    }

    /// The live merge extends the trailing utterance as whisper gets more
    /// audio. The delta already re-sends that entry for the client to
    /// replace, so it is not a removal — and neither is deleting the LAST
    /// line, which the same replace rule (plus a shrinking
    /// `next_segment_index`) covers.
    func test_rewriting_the_trailing_line_is_not_a_removal() {
        let before = [seg(0, "alpha"), seg(1, "beta")]
        let after = [seg(0, "alpha"), Segment(start: 1, end: 4, text: "beta gamma delta")]
        XCTAssertFalse(LiveTranscriptSnapshot.segmentsWereRemoved(from: before, to: after))
    }

    /// Live diarization labels land on lines published seconds earlier.
    /// Treating that as a removal would force a full resend on most ticks of
    /// any multi-speaker meeting, so `speaker` is deliberately not compared.
    func test_a_late_speaker_label_on_an_older_line_is_not_a_removal() {
        let before = [seg(0, "alpha"), seg(1, "beta"), seg(2, "gamma")]
        var after = before
        after[0].speaker = "SPEAKER_00"
        after[1].speaker = "SPEAKER_01"
        XCTAssertFalse(LiveTranscriptSnapshot.segmentsWereRemoved(from: before, to: after))
    }

    // MARK: - Cross-version decoding

    /// The field is optional so a helper built after this change still decodes
    /// a snapshot written by an app built before it. A non-optional `Int`
    /// would throw, `read` would swallow it as `nil`, and `get_live_transcript`
    /// would report "not recording" in the middle of a live meeting.
    func test_a_snapshot_without_the_removal_marker_still_decodes() throws {
        let json = """
        {"liveTranscriptAvailable":true,"recordingStartedAt":"2026-01-01T00:00:00Z",\
        "revision":3,"segments":[{"end":1,"start":0,"text":"alpha"}],"sessionID":\
        "\(UUID().uuidString)","speakerNames":{},"state":"recording",\
        "updatedAt":"2026-01-01T00:01:00Z","version":1}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snap = try decoder.decode(LiveTranscriptSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(snap.segmentsRemovedAtRevision)
        XCTAssertEqual(snap.segments.map(\.text), ["alpha"])
    }
}
