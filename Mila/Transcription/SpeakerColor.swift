import SwiftUI
import TranscriptionCore

/// Stable per-speaker color for the transcript UI. When diarization finds
/// more than one speaker, each raw `SPEAKER_NN` ID gets its own color so a
/// multi-speaker conversation is scannable at a glance instead of relying
/// solely on the "Speaker A" / "Speaker B" text label.
///
/// The index is parsed directly from the raw diarizer ID (not hashed from
/// the label) so the same speaker keeps the same color across every
/// render of a recording, live or post-processed.
private let speakerColorPalette: [Color] = [
    .blue, .green, .orange, .purple, .pink, .teal, .indigo, .brown
]

extension String {
    var speakerColor: Color {
        let index: Int
        if hasPrefix("SPEAKER_"), let n = Int(dropFirst("SPEAKER_".count)), n >= 0 {
            index = n
        } else {
            // Real diarizer IDs are always `SPEAKER_NN`; this only covers
            // non-standard IDs. `hashValue` is randomized per process, so it
            // can't be used here without breaking the "stable color" promise
            // across app relaunches — sum unicode scalars instead.
            index = abs(unicodeScalars.reduce(0) { $0 &+ Int($1.value) })
        }
        return speakerColorPalette[index % speakerColorPalette.count]
    }
}

/// Segment types that carry a diarizer speaker ID — `TranscriptSegment`
/// (post-recording transcript) and `LiveSegment` (live transcript).
protocol SpeakerBearingSegment {
    var speaker: String? { get }
}

extension TranscriptSegment: SpeakerBearingSegment {}
extension LiveSegment: SpeakerBearingSegment {}

extension Sequence where Element: SpeakerBearingSegment {
    /// True once at least two distinct speaker IDs have been seen. Short-
    /// circuits as soon as a second distinct speaker turns up rather than
    /// building a full `Set` of every speaker ID — matters for the live
    /// transcript, which re-evaluates this on every growing-segment render.
    var hasMultipleSpeakers: Bool {
        var firstSpeaker: String?
        for segment in self {
            guard let speaker = segment.speaker else { continue }
            if let firstSpeaker {
                if speaker != firstSpeaker { return true }
            } else {
                firstSpeaker = speaker
            }
        }
        return false
    }
}
