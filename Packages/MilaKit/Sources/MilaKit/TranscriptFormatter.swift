import Foundation

/// Minimal shape TranscriptFormatter needs from a transcript segment.
/// Both the app's `TranscriptSegment` (TranscriptionCore) and MilaKit's own
/// stored/live segment types conform, so the formatter lives here without
/// dragging the whisper.cpp-linked TranscriptionCore into the MCP helper.
public protocol SpeakerTextSegment {
    var text: String { get }
    /// Raw diarizer ID (`SPEAKER_00`), nil when diarization didn't run.
    var speaker: String? { get }
}

public enum TranscriptFormatter {

    /// Plain-text rendering of `segments` suitable for the clipboard or for
    /// piping into an LLM prompt. When any segment carries a speaker label
    /// (diarization ran), each turn is prefixed with the speaker's label and
    /// consecutive segments from the same speaker collapse into one
    /// paragraph. When no segment has a speaker, falls back to `fallback`
    /// — the trimmed full-text join the rest of the app stores.
    ///
    /// `names` maps raw diarizer IDs (`SPEAKER_00`) to user-assigned names;
    /// unnamed speakers keep the raw ID. Turns collapse on the RESOLVED
    /// label, so two raw IDs the user named identically (their fix for an
    /// over-split speaker) merge into one paragraph.
    ///
    /// Matches the SRT exporter's prefix format so the clipboard text and
    /// the on-disk `.srt` use the same speaker labels.
    public static func plainText<S: SpeakerTextSegment>(
        segments: [S], fallback: String, names: [String: String] = [:]
    ) -> String {
        guard segments.contains(where: { $0.speaker != nil }) else { return fallback }

        var lines: [String] = []
        var currentSpeaker: String?? = .none
        var buffer = ""

        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let speaker = seg.speaker.map { names[$0] ?? $0 }

            if currentSpeaker == .none {
                currentSpeaker = .some(speaker)
                buffer = text
                continue
            }

            if currentSpeaker == .some(speaker) {
                buffer += " " + text
            } else {
                lines.append(format(speaker: currentSpeaker.flatMap { $0 }, text: buffer))
                currentSpeaker = .some(speaker)
                buffer = text
            }
        }

        if !buffer.isEmpty {
            lines.append(format(speaker: currentSpeaker.flatMap { $0 }, text: buffer))
        }

        return lines.joined(separator: "\n")
    }

    /// The one way to rebuild a recording's full text from its segments.
    ///
    /// Used wherever the `.txt` sidecar and the legacy inline `fullText`
    /// are both unavailable: `MilaStoreReader.transcriptText`, the app's
    /// `RecordingStore` load fallback, and the live poll's `transcript`
    /// field. Those three used to disagree — the first two joined with NO
    /// separator, the third with `" "` plus a trim — and the disagreement
    /// was not cosmetic, because the two segment-producing paths store
    /// text differently:
    ///
    ///   * whisper's batch segments arrive with a LEADING space
    ///     (`" Hello team"`), so a separator-free join is already correctly
    ///     spaced and adding `" "` would double every gap;
    ///   * `LiveTranscriber` trims each segment on construction, so a
    ///     separator-free join glues words together — the exact
    ///     `"hello teamhi, thanks for joining"` CodeRabbit flagged on #183.
    ///
    /// Segments in `recordings.json` can come from EITHER path, so neither
    /// join is right on its own. Trimming each piece and re-joining with a
    /// single space is right for both, and dropping now-empty pieces keeps
    /// whitespace-only segments from leaving double spaces behind.
    public static func joinedFullText<S: SpeakerTextSegment>(segments: [S]) -> String {
        segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func format(speaker: String?, text: String) -> String {
        guard let speaker else { return text }
        return "\(speaker): \(text)"
    }
}
