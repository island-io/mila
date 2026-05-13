import Foundation

enum TranscriptExporter {

    static func writeSRT(for recording: Recording, in directory: URL) {
        let srtName = (recording.audioFileName as NSString).deletingPathExtension + ".srt"
        let url = directory.appendingPathComponent(srtName)
        let segments = recording.segments
        guard !segments.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        var srt = ""
        for (idx, seg) in segments.enumerated() {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let prefix = seg.speaker.map { $0 + ": " } ?? ""
            srt += "\(idx + 1)\n"
            srt += "\(formatSRTTime(seg.start)) --> \(formatSRTTime(seg.end))\n"
            srt += "\(prefix)\(text)\n\n"
        }

        do {
            try srt.write(to: url, atomically: true, encoding: .utf8)
            print("TranscriptExporter: wrote \(srtName)")
        } catch {
            print("TranscriptExporter: failed to write \(srtName): \(error)")
        }
    }

    private static func formatSRTTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%06.3f", h, m, s).replacingOccurrences(of: ".", with: ",")
    }
}
