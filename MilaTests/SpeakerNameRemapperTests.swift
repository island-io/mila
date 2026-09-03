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

    // MARK: - Retired names (island-io/mila#254)

    /// The headline case. The live diarizer over-segmented one person into a
    /// long fragment and a short one, the user named BOTH (or a recogniser
    /// did), and the offline pass merges them: the short fragment's name is
    /// dropped from the recording entirely. Its voice-profile contribution
    /// has to come back out, because there is no longer a label to un-name.
    func test_a_collapsed_fragment_retires_the_name_the_remap_drops() {
        let old = [seg(0, 8, "SPEAKER_00"), seg(8, 10, "SPEAKER_01")]
        let new = rekeyed(old, to: ["SPEAKER_00", "SPEAKER_00"])
        let names = ["SPEAKER_00": "Daniel", "SPEAKER_01": "Noa"]

        XCTAssertEqual(SpeakerNameRemapper.remap(names: names, from: old, to: new),
                       ["SPEAKER_00": "Daniel"],
                       "precondition: the dominant fragment's name is the one that survives")
        XCTAssertEqual(SpeakerNameRemapper.retiredNames(names: names, from: old, to: new),
                       ["SPEAKER_01": "Noa"],
                       "Noa's label is gone from the recording, so her profile must give "
                       + "this recording's observation back — Daniel's must not")
    }

    /// A name that MOVES is not a name that is retired. This is the case a
    /// key-by-key diff of `speakerNames` gets wrong in both directions: the
    /// keys are renumbered, so `SPEAKER_00` losing "Daniel" looks like a drop
    /// while the pair is in fact intact on `SPEAKER_01`.
    func test_a_name_that_moves_to_another_id_is_not_retired() {
        let old = [seg(0, 5, "SPEAKER_00"), seg(5, 10, "SPEAKER_01")]
        let new = rekeyed(old, to: ["SPEAKER_01", "SPEAKER_00"])
        let names = ["SPEAKER_00": "Daniel"]

        XCTAssertEqual(SpeakerNameRemapper.remap(names: names, from: old, to: new),
                       ["SPEAKER_01": "Daniel"])
        XCTAssertTrue(SpeakerNameRemapper.retiredNames(names: names, from: old, to: new).isEmpty,
                      "the name and its observation both land on SPEAKER_01, so retiring it "
                      + "would subtract a contribution the profile still backs — twice, once "
                      + "the user un-names it for real")
    }

    /// A split duplicates the name onto both halves, but
    /// `ObservedVoiceSnapshots.remapSpeakerIDs` refuses to duplicate the
    /// observation (un-naming both halves would subtract it twice) and drops
    /// it. The label survives with nothing backing it, so the contribution is
    /// retired even though the string is still on the row.
    func test_a_split_retires_the_name_it_duplicates() {
        let old = [seg(0, 5, "SPEAKER_00"), seg(5, 10, "SPEAKER_00")]
        let new = rekeyed(old, to: ["SPEAKER_00", "SPEAKER_01"])
        let names = ["SPEAKER_00": "Daniel"]

        XCTAssertEqual(SpeakerNameRemapper.remap(names: names, from: old, to: new),
                       ["SPEAKER_00": "Daniel", "SPEAKER_01": "Daniel"])
        XCTAssertEqual(SpeakerNameRemapper.retiredNames(names: names, from: old, to: new),
                       ["SPEAKER_00": "Daniel"])
    }

    func test_retiring_ignores_ids_that_were_never_named() {
        let old = [seg(0, 8, "SPEAKER_00"), seg(8, 10, "SPEAKER_01")]
        let new = rekeyed(old, to: ["SPEAKER_00", "SPEAKER_00"])

        XCTAssertTrue(SpeakerNameRemapper.retiredNames(names: [:], from: old, to: new).isEmpty)
        XCTAssertTrue(
            SpeakerNameRemapper.retiredNames(names: ["SPEAKER_00": "Daniel"],
                                             from: old, to: new).isEmpty,
            "the collapsed fragment was never named, so it contributed nothing to subtract")
    }

    /// An old id that the pass left with no labelled utterances at all
    /// dominates nothing, so its name — and its contribution — are retired.
    func test_an_id_the_pass_stopped_labelling_is_retired() {
        let old = [seg(0, 5, "SPEAKER_00"), seg(5, 10, "SPEAKER_01")]
        let new = rekeyed(old, to: ["SPEAKER_00", nil])
        let names = ["SPEAKER_00": "Daniel", "SPEAKER_01": "Noa"]

        XCTAssertEqual(SpeakerNameRemapper.remap(names: names, from: old, to: new),
                       ["SPEAKER_00": "Daniel"])
        XCTAssertEqual(SpeakerNameRemapper.retiredNames(names: names, from: old, to: new),
                       ["SPEAKER_01": "Noa"])
    }

    func test_retiring_on_an_identity_rekey_notifies_nothing() {
        let old = [seg(0, 5, "SPEAKER_00"), seg(5, 10, "SPEAKER_01")]
        let new = rekeyed(old, to: ["SPEAKER_00", "SPEAKER_01"])

        XCTAssertTrue(
            SpeakerNameRemapper.retiredNames(names: ["SPEAKER_00": "Daniel",
                                                     "SPEAKER_01": "Noa"],
                                             from: old, to: new).isEmpty,
            "nothing changed hands, so nothing may be subtracted")
    }
}
