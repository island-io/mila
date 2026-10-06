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

/// A segment that also knows WHEN it was spoken. SRT needs timings and the
/// plain-text renderers do not, so this refines `SpeakerTextSegment` rather
/// than widening it — a type that can only say what was said (a test stub,
/// a future text-only source) still conforms to the base protocol.
public protocol TimedSpeakerTextSegment: SpeakerTextSegment {
    /// Seconds from the start of the recording.
    var start: Double { get }
    var end: Double { get }
}

public enum TranscriptFormatter {

    // MARK: - SRT

    /// SubRip subtitle rendering of `segments`: one cue per non-blank
    /// segment, numbered sequentially after blanks are dropped, with the
    /// speaker's resolved label as a `Name: ` prefix when diarization ran.
    /// Returns `""` when there is nothing to write.
    ///
    /// This is THE SRT formatter — the app's `TranscriptExporter` (export
    /// menus and the auto-written `.srt` sidecar) and the MCP helper's
    /// `get_transcript(format: "srt")` both call it, so the file a user
    /// exports and the text a client fetches are byte-identical.
    ///
    /// Unlike `plainText`, consecutive same-speaker segments are NOT
    /// collapsed: each cue keeps its own timing.
    public static func srt<S: TimedSpeakerTextSegment>(
        segments: [S], names: [String: String] = [:]
    ) -> String {
        let cues = srtCues(segments: segments, names: names)
        return cues.isEmpty ? "" : cues.joined(separator: "\n\n") + "\n\n"
    }

    /// The individual cues `srt` joins, each already formatted as
    /// `"n\nHH:MM:SS,mmm --> HH:MM:SS,mmm\n[Name: ]text"`. Exposed so a
    /// caller that has to cap output size (`get_transcript`'s `max_chars`)
    /// can drop whole cues from the end instead of cutting one in half,
    /// which would leave an invalid file.
    public static func srtCues<S: TimedSpeakerTextSegment>(
        segments: [S], names: [String: String] = [:]
    ) -> [String] {
        var entries: [String] = []
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let seqNum = entries.count + 1
            let prefix = seg.speaker.map { (names[$0] ?? $0) + ": " } ?? ""
            entries.append("\(seqNum)\n\(srtTimestamp(seg.start)) --> \(srtTimestamp(seg.end))\n\(prefix)\(text)")
        }
        return entries
    }

    static func srtTimestamp(_ seconds: Double) -> String {
        // Round to whole milliseconds FIRST, then decompose. The previous
        // version truncated hours/minutes from the raw double but let
        // `%06.3f` round the seconds field, so inputs within 0.5ms below a
        // minute boundary printed an invalid :60 seconds field (59.9996 →
        // "00:00:60,000" instead of "00:01:00,000"). Local whisper sits on
        // a 10ms grid, but the remote path passes through the server's
        // full-precision floats.
        let totalMillis = Int((seconds * 1000).rounded())
        let h = totalMillis / 3_600_000
        let m = (totalMillis % 3_600_000) / 60_000
        let s = (totalMillis % 60_000) / 1_000
        let ms = totalMillis % 1_000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - Plain text

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
    ///
    /// `fallback` is an `@autoclosure`, and that is load-bearing rather than
    /// a micro-optimisation. It is consulted on exactly one path — no segment
    /// carries a speaker — so for a diarized recording producing it is work
    /// with no observable effect. `MilaStoreReader.namedTranscript` passes an
    /// expression that READS A FILE, and it used to be evaluated eagerly for
    /// every recording a search touched: the "N synchronous file reads per
    /// `search_transcripts` call" of #201. Every call site passes a pure
    /// expression, so nothing reads differently at the call sites; deferring
    /// it is the whole point, so do not hoist one into a `let`.
    public static func plainText<S: SpeakerTextSegment>(
        segments: [S], fallback: @autoclosure () -> String, names: [String: String] = [:]
    ) -> String {
        guard segments.contains(where: { $0.speaker != nil }) else { return fallback() }

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
