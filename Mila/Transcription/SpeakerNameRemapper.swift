import Foundation
import TranscriptionCore

/// Carries user-assigned speaker names across the post-stop offline
/// re-diarization, which re-keys every `SPEAKER_NN` label (global
/// clustering assigns IDs by first-speaking order, unrelated to the
/// live diarizer's IDs). Without the remap, a name assigned to live
/// `SPEAKER_03` could silently land on — or vanish from — a different
/// person in the finalized recording.
///
/// Works because `TranscriptionService.rediarizeSegments` only
/// reassigns `.speaker` on the SAME segment array: `old[i]` and
/// `new[i]` are the same utterance, so per-index pairs tell us which
/// old speaker each new speaker was.
enum SpeakerNameRemapper {

    /// `votes[newID][oldID]` = summed duration of segments that carried
    /// `oldID` before the pass and `newID` after. The small floor keeps
    /// zero-duration segments counted (degrades to a per-segment vote
    /// instead of dropping them).
    private static func votes(from old: [TranscriptSegment],
                              to new: [TranscriptSegment]) -> [String: [String: Double]] {
        var votes: [String: [String: Double]] = [:]
        for (o, n) in zip(old, new) {
            guard let oldID = o.speaker, let newID = n.speaker else { continue }
            let duration = max(n.end - n.start, 0.001)
            votes[newID, default: [:]][oldID, default: 0] += duration
        }
        return votes
    }

    /// For each **new** speaker ID, the old ID that dominates it by summed
    /// segment duration. Handles the offline pass merging over-segmented
    /// live speakers (the dominant old ID's name wins) and splitting one
    /// live speaker into two (the name propagates to both halves).
    ///
    /// `ObservedVoiceSnapshots.remapSpeakerIDs` consumes the same mapping, so
    /// a new id's carried embedding comes from the very fragment its NAME
    /// came from. That pairing is what keeps un-naming an exact inverse of
    /// naming across a re-key — feed the two from different mappings and an
    /// observation ends up subtracted from a profile it was never added to.
    static func dominantOldIDs(from old: [TranscriptSegment],
                               to new: [TranscriptSegment]) -> [String: String] {
        var dominant: [String: String] = [:]
        for (newID, tally) in votes(from: old, to: new) {
            let winner = tally.max { a, b in
                if a.value != b.value { return a.value < b.value }
                return a.key > b.key  // deterministic tie-break: lower old ID wins
            }?.key
            if let winner { dominant[newID] = winner }
        }
        return dominant
    }

    /// Carry each new speaker ID's name over from the old ID that dominates
    /// it.
    static func remap(names: [String: String],
                      from old: [TranscriptSegment],
                      to new: [TranscriptSegment]) -> [String: String] {
        remap(names: names, dominantOldIDs: dominantOldIDs(from: old, to: new))
    }

    /// `remap` for a caller that already holds the dominance mapping. The
    /// re-diarize path needs it three times in a row — for the names, for the
    /// names it RETIRES, and for the observations — and each
    /// `dominantOldIDs` call re-tallies every segment. Same mapping for all
    /// three is also the correctness requirement, not just a saving: see
    /// `retiredNames`.
    static func remap(names: [String: String],
                      dominantOldIDs: [String: String]) -> [String: String] {
        guard !names.isEmpty else { return [:] }
        var remapped: [String: String] = [:]
        for (newID, oldID) in dominantOldIDs {
            if let name = names[oldID] { remapped[newID] = name }
        }
        return remapped
    }

    /// The `[oldID: name]` pairs the re-key **retires**: names whose observed
    /// embedding does not travel with them onto a new id.
    ///
    /// **What this is for.** Naming a speaker folds that speaker's observed
    /// embedding into the named voice profile
    /// (`RecordingStore.onSpeakerNamed`), and un-naming subtracts it back out.
    /// The subtraction is only an exact inverse while the profile's weight
    /// stays reconstructible from the observations backing it — so every
    /// operation that changes which observation backs which name has to
    /// update both sides. A re-key is such an operation, and it used to
    /// update neither: `remap` silently dropped names, leaving their
    /// contributions in a profile with no label left to un-name
    /// (island-io/mila#254).
    ///
    /// **The rule, and why it is exactly this.** An old id's name and its
    /// observation travel together onto exactly one new id — `remap` takes
    /// the name from the dominant old id, and
    /// `ObservedVoiceSnapshots.remapSpeakerIDs` takes the observation from
    /// the same one — **iff that old id dominates exactly one new id.** So:
    ///
    /// | old id, with a name          | name after | observation after | retired |
    /// |------------------------------|------------|-------------------|---------|
    /// | dominates one new id         | on that id | on that id        | no — the pair is intact, and subtracting would take back weight the profile still backs |
    /// | dominates none (a collapse's non-dominant fragment) | gone | dropped | **yes** — this issue's headline case |
    /// | dominates two or more (a split) | duplicated onto each | dropped, to avoid a double subtract | **yes** — the label survives with nothing backing it |
    ///
    /// The middle row is why this exists. The last row is why the rule is
    /// "dominates exactly one" rather than "has no surviving label": the name
    /// string is still on the row, but the thing that could reverse it is
    /// gone, so the contribution has to come out now or never.
    ///
    /// **This mirrors `ObservedVoiceSnapshots.remapSpeakerIDs`' survival
    /// rule** (`timesDominant[oldID] == 1`) and has to keep mirroring it:
    /// retiring a name whose observation IS carried over would subtract the
    /// same contribution twice, and the second subtraction comes out of the
    /// profile's other recordings.
    /// `ObservedVoiceSnapshotsTests.test_retiring_a_name_mirrors_which_observations_survive`
    /// pins the two together.
    ///
    /// Names for ids that were never observed are returned too: the hook
    /// resolves them against the snapshot and a missing observation subtracts
    /// nothing, so an unobserved id costs one no-op rather than needing a
    /// second source of truth here.
    static func retiredNames(names: [String: String],
                             dominantOldIDs: [String: String]) -> [String: String] {
        guard !names.isEmpty else { return [:] }
        var timesDominant: [String: Int] = [:]
        for oldID in dominantOldIDs.values { timesDominant[oldID, default: 0] += 1 }
        return names.filter { timesDominant[$0.key] != 1 }
    }

    /// `retiredNames` from the two segment arrays, for callers that do not
    /// already hold the dominance mapping.
    static func retiredNames(names: [String: String],
                             from old: [TranscriptSegment],
                             to new: [TranscriptSegment]) -> [String: String] {
        retiredNames(names: names, dominantOldIDs: dominantOldIDs(from: old, to: new))
    }
}
