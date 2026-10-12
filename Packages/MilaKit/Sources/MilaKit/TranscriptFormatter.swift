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
        srt(cues: srtCues(segments: segments, names: names))
    }

    /// What follows every cue in a rendered file, the last one included:
    /// SRT separates cues with a blank line, and a trailing one keeps the
    /// file well-formed for strict players. The handler's `max_chars`
    /// accounting budgets with this same constant, so the per-cue cost it
    /// assumes is the real one.
    static let srtCueTerminator = "\n\n"

    /// The assembly half of `srt`: joins cues already produced by
    /// `srtCues`. Exposed so a caller that dropped cues to fit a size cap
    /// (`get_transcript`'s `max_chars`) renders the remainder with exactly
    /// the separators `srt(segments:)` would have used — the format
    /// knowledge stays in one place.
    public static func srt(cues: [String]) -> String {
        cues.map { $0 + srtCueTerminator }.joined()
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
            // Same label resolution and `Name: text` shape as `plainText`,
            // so the cue prefix and the clipboard text cannot drift apart.
            let line = format(speaker: seg.speaker.map { names[$0] ?? $0 }, text: cueText(text))
            entries.append("\(seqNum)\n\(srtTimestamp(seg.start)) --> \(srtTimestamp(seg.end))\n\(line)")
        }
        return entries
    }

    /// `trimmedText` with no blank line left inside it. A blank line is
    /// SRT's one and only cue delimiter, so a segment whose text carried an
    /// interior `\n\n` — or a whitespace-only line, which lenient players
    /// read as blank too — came back from the file as TWO cues, the second
    /// with no number and no timing: strict players reject it, lenient ones
    /// mis-time it. Empty and whitespace-only lines are dropped and the rest
    /// rejoined with `\n`, so one segment is one cue whatever its text
    /// carries. A line break on its own is a legal two-line cue and stays.
    ///
    /// Text with no line break in it is returned as-is — not re-split and
    /// re-joined into equal bytes, the same `String` — which is what keeps
    /// the app's `.srt` export unchanged for every segment whisper produces.
    /// Every Unicode line terminator counts (`CharacterSet.newlines`: `\n`,
    /// `\r`, VT, FF, NEL, U+2028, U+2029), not only the `\r`/`\n` an SRT
    /// parser proper splits on: a reader built on a generic line splitter
    /// such as Python's `str.splitlines()` breaks on all of them, so
    /// `"a\u{2028}\u{2028}b"` would split the cue just as `"a\n\nb"` did.
    /// Each surviving break rejoins as `\n`, the separator the rest of the
    /// file already uses (so `\r\n` becomes `\n`).
    static func cueText(_ trimmedText: String) -> String {
        guard trimmedText.rangeOfCharacter(from: cueLineBreaks) != nil else { return trimmedText }
        return trimmedText.components(separatedBy: cueLineBreaks)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }

    private static let cueLineBreaks = CharacterSet.newlines

    static func srtTimestamp(_ seconds: Double) -> String {
        // Round to whole milliseconds FIRST, then decompose. The previous
        // version truncated hours/minutes from the raw double but let
        // `%06.3f` round the seconds field, so inputs within 0.5ms below a
        // minute boundary printed an invalid :60 seconds field (59.9996 →
        // "00:00:60,000" instead of "00:01:00,000"). Local whisper sits on
        // a 10ms grid, but the remote path passes through the server's
        // full-precision floats.
        //
        // `seconds` comes straight out of recordings.json — user-editable,
        // and written by older app versions — and this now runs inside the
        // long-lived mila-mcp process, where `Int(_:)` trapping on one bad
        // row would take the server down for every client. So a stated,
        // bounded imprecision instead of a trap: a non-finite, negative or
        // absurd value is pinned to the nearest end of
        // 00:00:00,000 … 99:59:59,999 — the widest value SRT's two-digit
        // hour field holds, so the pinned cue is still in-format. No
        // recording is that long, and a negative start is an upstream bug,
        // not a time before the file began. (`max`/`min` pass NaN through,
        // hence the explicit check.)
        let rounded = (seconds * 1000).rounded()
        let maxMillis = 359_999_999.0 // 99:59:59,999
        let totalMillis = Int(rounded.isNaN ? 0 : min(max(rounded, 0), maxMillis))
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
