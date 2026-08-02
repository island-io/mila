import Foundation
import TranscriptionCore

enum TranscriptExporter {

    /// Sidecar variant: write the SRT next to the recording's audio file.
    /// Called automatically by `TranscriptionService` after a successful
    /// transcription so every completed recording has a ready-to-share
    /// .srt file alongside its .wav.
    static func writeSRT(for recording: Recording, in directory: URL) {
        let srtName = (recording.audioFileName as NSString).deletingPathExtension + ".srt"
        let url = directory.appendingPathComponent(srtName)
        let body = srtBody(for: recording)
        guard !body.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            print("TranscriptExporter: wrote \(srtName)")
        } catch {
            print("TranscriptExporter: failed to write \(srtName): \(error)")
        }
    }

    /// Explicit-destination variant: write the SRT to an arbitrary user-
    /// chosen URL. Used by the "Export Subtitles (.srt)…" command in the
    /// history context menu so users can drop subtitles next to a source
    /// video file. Throws so the caller can surface failures via NSAlert.
    static func writeSRT(for recording: Recording, to url: URL) throws {
        try writeSRT(segments: recording.segments, to: url, names: recording.speakerNames)
    }

    /// Raw-segments variant: write an SRT for a segment list that isn't
    /// (yet) attached to a saved `Recording`. Used by the mid-recording
    /// "Export SRT…" button in the live transcript pane, which snapshots
    /// `LiveTranscriber.segments` while the recording is still running.
    static func writeSRT(segments: [TranscriptSegment], to url: URL,
                         names: [String: String] = [:]) throws {
        let body = srtBody(for: segments, names: names)
        guard !body.isEmpty else {
            throw NSError(domain: "TranscriptExporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No transcript segments to export."])
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Format the SRT content for `recording`. Returns empty string when
    /// there's nothing to write (no segments, or every segment is blank).
    static func srtBody(for recording: Recording) -> String {
        srtBody(for: recording.segments, names: recording.speakerNames)
    }

    /// Format SRT content for a raw segment list. Returns empty string
    /// when there's nothing to write (no segments, or every segment is
    /// blank). `names` substitutes user-assigned speaker names for raw
    /// diarizer IDs in the cue prefix; unnamed speakers keep the raw ID.
    static func srtBody(for segments: [TranscriptSegment],
                        names: [String: String] = [:]) -> String {
        guard !segments.isEmpty else { return "" }

        var entries: [String] = []
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let seqNum = entries.count + 1
            let prefix = seg.speaker.map { (names[$0] ?? $0) + ": " } ?? ""
            entries.append("\(seqNum)\n\(formatSRTTime(seg.start)) --> \(formatSRTTime(seg.end))\n\(prefix)\(text)")
        }
        return entries.isEmpty ? "" : entries.joined(separator: "\n\n") + "\n\n"
    }

    private static func formatSRTTime(_ seconds: Double) -> String {
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
}
