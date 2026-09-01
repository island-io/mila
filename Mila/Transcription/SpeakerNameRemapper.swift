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

    /// For each **old** speaker ID, the new ID that took most of it — the
    /// transpose of `dominantOldIDs`, and the mapping the observed
    /// embeddings travel on.
    ///
    /// **Why the embeddings need the other direction.** A name may be
    /// duplicated across a re-key: the offline pass splitting one live
    /// speaker in two gives both halves the same name, harmlessly. An
    /// embedding may not, because un-naming both halves would then subtract
    /// one observation twice. Keying old→new makes that unrepresentable —
    /// a dictionary gives each old id exactly one destination — while still
    /// letting several old ids land on the same new one, which is the case
    /// that matters most: collapsing live over-segmentation is the entire
    /// reason the offline pass runs, and `RecognisedSpeakerAssigner.finish`
    /// has already folded *every* fragment into the profile. Those have to
    /// be combined rather than reduced to the dominant one, or un-naming
    /// gives back a fraction of what the recording contributed. See
    /// `ObservedVoiceSnapshots.remapSpeakerIDs`.
    static func owningNewIDs(from old: [TranscriptSegment],
                             to new: [TranscriptSegment]) -> [String: String] {
        // Transpose the votes: for each old id, which new id took most of it.
        var byOldID: [String: [String: Double]] = [:]
        for (newID, tally) in votes(from: old, to: new) {
            for (oldID, duration) in tally {
                byOldID[oldID, default: [:]][newID, default: 0] += duration
            }
        }
        var owner: [String: String] = [:]
        for (oldID, tally) in byOldID {
            let winner = tally.max { a, b in
                if a.value != b.value { return a.value < b.value }
                return a.key > b.key  // deterministic tie-break: lower new ID wins
            }?.key
            if let winner { owner[oldID] = winner }
        }
        return owner
    }

    /// Carry each new speaker ID's name over from the old ID that dominates
    /// it.
    static func remap(names: [String: String],
                      from old: [TranscriptSegment],
                      to new: [TranscriptSegment]) -> [String: String] {
        guard !names.isEmpty else { return [:] }
        var remapped: [String: String] = [:]
        for (newID, oldID) in dominantOldIDs(from: old, to: new) {
            if let name = names[oldID] { remapped[newID] = name }
        }
        return remapped
    }
}
