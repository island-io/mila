import Foundation

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
        let body = srtBody(for: recording)
        guard !body.isEmpty else {
            throw NSError(domain: "TranscriptExporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No transcript segments to export."])
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Format the SRT content for `recording`. Returns empty string when
    /// there's nothing to write (no segments, or every segment is blank).
    static func srtBody(for recording: Recording) -> String {
        let segments = recording.segments
        guard !segments.isEmpty else { return "" }

        var entries: [String] = []
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let seqNum = entries.count + 1
            let prefix = seg.speaker.map { $0 + ": " } ?? ""
            entries.append("\(seqNum)\n\(formatSRTTime(seg.start)) --> \(formatSRTTime(seg.end))\n\(prefix)\(text)")
        }
        return entries.isEmpty ? "" : entries.joined(separator: "\n\n") + "\n\n"
    }

    private static func formatSRTTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%06.3f", h, m, s).replacingOccurrences(of: ".", with: ",")
    }
}
