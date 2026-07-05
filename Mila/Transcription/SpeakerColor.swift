import SwiftUI

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
            index = abs(hashValue)
        }
        return speakerColorPalette[index % speakerColorPalette.count]
    }
}
