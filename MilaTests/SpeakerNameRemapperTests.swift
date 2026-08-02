import XCTest
import TranscriptionCore
@testable import Mila

final class SpeakerNameRemapperTests: XCTestCase {

    private func seg(_ start: Double, _ end: Double, _ speaker: String?) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: "t", speaker: speaker)
    }

    /// Re-key a segment list's speakers the way `rediarizeSegments` does:
    /// same array, only `.speaker` changes per index.
    private func rekeyed(_ old: [TranscriptSegment], to newSpeakers: [String?]) -> [TranscriptSegment] {
        var out = old
        for i in out.indices { out[i].speaker = newSpeakers[i] }
        return out
    }

    func test_identity_rekey_keeps_names() {
        let old = [seg(0, 5, "SPEAKER_00"), seg(5, 10, "SPEAKER_01")]
        let new = rekeyed(old, to: ["SPEAKER_00", "SPEAKER_01"])
        let remapped = SpeakerNameRemapper.remap(names: ["SPEAKER_00": "Daniel"],
                                                 from: old, to: new)
        XCTAssertEqual(remapped, ["SPEAKER_00": "Daniel"])
    }

    func test_swapped_ids_follow_the_utterances() {
        // The offline pass assigned the IDs in the opposite order — the
        // name must follow the person (their utterances), not the ID.
        let old = [seg(0, 5, "SPEAKER_00"), seg(5, 10, "SPEAKER_01")]
        let new = rekeyed(old, to: ["SPEAKER_01", "SPEAKER_00"])
        let remapped = SpeakerNameRemapper.remap(names: ["SPEAKER_00": "Daniel"],
                                                 from: old, to: new)
        XCTAssertEqual(remapped, ["SPEAKER_01": "Daniel"])
    }

    func test_merge_dominant_name_wins_by_duration() {
        // Live over-segmented one person into 00 (8s, named) and 01 (2s,
        // named differently); offline merges them into a single SPEAKER_00.
        let old = [seg(0, 8, "SPEAKER_00"), seg(8, 10, "SPEAKER_01")]
        let new = rekeyed(old, to: ["SPEAKER_00", "SPEAKER_00"])
        let remapped = SpeakerNameRemapper.remap(
            names: ["SPEAKER_00": "Daniel", "SPEAKER_01": "Noa"],
            from: old, to: new)
        XCTAssertEqual(remapped, ["SPEAKER_00": "Daniel"])
    }

    func test_split_propagates_name_to_both_halves() {
        // Live lumped two utterances under one (named) speaker; offline
        // splits them. Both halves keep the name — better than silently
        // dropping it from one, and trivially correctable in the UI.
        let old = [seg(0, 5, "SPEAKER_00"), seg(5, 10, "SPEAKER_00")]
        let new = rekeyed(old, to: ["SPEAKER_00", "SPEAKER_01"])
        let remapped = SpeakerNameRemapper.remap(names: ["SPEAKER_00": "Daniel"],
                                                 from: old, to: new)
        XCTAssertEqual(remapped, ["SPEAKER_00": "Daniel", "SPEAKER_01": "Daniel"])
    }

    func test_unnamed_speakers_produce_no_entries() {
        let old = [seg(0, 5, "SPEAKER_00"), seg(5, 10, "SPEAKER_01")]
        let new = rekeyed(old, to: ["SPEAKER_01", "SPEAKER_00"])
        let remapped = SpeakerNameRemapper.remap(names: ["SPEAKER_00": "Daniel"],
                                                 from: old, to: new)
        XCTAssertNil(remapped["SPEAKER_00"],
                     "The unnamed old SPEAKER_01 (now SPEAKER_00) must stay unnamed")
    }

    func test_nil_speaker_segments_are_ignored() {
        let old = [seg(0, 5, nil), seg(5, 10, "SPEAKER_00")]
        let new = rekeyed(old, to: [nil, "SPEAKER_00"])
        let remapped = SpeakerNameRemapper.remap(names: ["SPEAKER_00": "Daniel"],
                                                 from: old, to: new)
        XCTAssertEqual(remapped, ["SPEAKER_00": "Daniel"])
    }

    func test_empty_inputs() {
        XCTAssertTrue(SpeakerNameRemapper.remap(names: [:], from: [], to: []).isEmpty)
        XCTAssertTrue(SpeakerNameRemapper.remap(names: ["SPEAKER_00": "D"], from: [], to: []).isEmpty)
    }

    func test_zero_duration_segments_still_vote() {
        // Degenerate timestamps (start == end) must not drop the vote.
        let old = [seg(3, 3, "SPEAKER_00")]
        let new = rekeyed(old, to: ["SPEAKER_01"])
        let remapped = SpeakerNameRemapper.remap(names: ["SPEAKER_00": "Daniel"],
                                                 from: old, to: new)
        XCTAssertEqual(remapped, ["SPEAKER_01": "Daniel"])
    }
}
