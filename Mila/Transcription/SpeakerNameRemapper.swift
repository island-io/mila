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

    /// For each new speaker ID, find the old ID that dominates it by
    /// summed segment duration and carry that old ID's name over.
    /// Handles the offline pass merging over-segmented live speakers
    /// (dominant name wins) and splitting one live speaker into two
    /// (the name propagates to both halves).
    static func remap(names: [String: String],
                      from old: [TranscriptSegment],
                      to new: [TranscriptSegment]) -> [String: String] {
        guard !names.isEmpty else { return [:] }

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

        var remapped: [String: String] = [:]
        for (newID, tally) in votes {
            let dominant = tally.max { a, b in
                if a.value != b.value { return a.value < b.value }
                return a.key > b.key  // deterministic tie-break: lower old ID wins
            }?.key
            if let dominant, let name = names[dominant] {
                remapped[newID] = name
            }
        }
        return remapped
    }
}
