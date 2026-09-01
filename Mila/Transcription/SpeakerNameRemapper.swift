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

    /// For each new speaker ID, the old ID that dominates it by summed
    /// segment duration. Handles the offline pass merging over-segmented
    /// live speakers (the dominant old ID wins) and splitting one live
    /// speaker into two (both halves map back to it).
    ///
    /// Exposed separately from `remap` because the *names* are not the only
    /// thing that has to survive a re-key: `ObservedVoiceSnapshots` carries
    /// the observed embeddings across the same boundary, and the two must
    /// move on identical evidence or a later un-name subtracts an
    /// observation from a profile it was never added to. See
    /// `ObservedVoiceSnapshots.remapSpeakerIDs`.
    static func dominantOldIDs(from old: [TranscriptSegment],
                               to new: [TranscriptSegment]) -> [String: String] {
        // votes[newID][oldID] = summed duration of segments where the
        // utterance carried oldID before and newID after. The small
        // floor keeps zero-duration segments counted (degrades to a
        // per-segment vote instead of dropping them).
        var votes: [String: [String: Double]] = [:]
        for (o, n) in zip(old, new) {
            guard let oldID = o.speaker, let newID = n.speaker else { continue }
            let duration = max(n.end - n.start, 0.001)
            votes[newID, default: [:]][oldID, default: 0] += duration
        }

        var dominant: [String: String] = [:]
        for (newID, tally) in votes {
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
        guard !names.isEmpty else { return [:] }
        var remapped: [String: String] = [:]
        for (newID, oldID) in dominantOldIDs(from: old, to: new) {
            if let name = names[oldID] { remapped[newID] = name }
        }
        return remapped
    }
}
