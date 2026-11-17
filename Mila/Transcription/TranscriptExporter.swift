import Foundation
import OSLog
import TranscriptionCore
import MilaKit

private let exporterLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                 category: "TranscriptExporter")

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
            // `srtName` is `recording.audioFileName` with the extension
            // swapped, and `audioFileName` comes from the recording's TITLE
            // (`RecordingStore.freshAudioURL(suggestedName:)`, and
            // `FileTranscriber`'s `safeStem` for imports). This line fires on
            // every completed transcription — the highest-volume title leak in
            // the app — so the name is `.private` and the recording's UUID is
            // the public correlation key. (Issue #213, CWE-532.)
            exporterLog.log("""
                wrote SRT for \(recording.id, privacy: .public) \
                (\(srtName, privacy: .private))
                """)
        } catch {
            // The error string needs the same care as the name: Cocoa quotes
            // the offending file — and its containing folder, which is the
            // user's chosen recordings directory — inside
            // `localizedDescription`. Domain + code stay public so "no
            // permission" is still distinguishable from a full disk or a
            // missing directory without exposing either.
            let ns = error as NSError
            exporterLog.error("""
                failed to write SRT for \(recording.id, privacy: .public) \
                (\(srtName, privacy: .private)) \
                [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)]: \
                \(error.localizedDescription, privacy: .private)
                """)
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
    ///
    /// The rendering itself lives in MilaKit (`TranscriptFormatter.srt`)
    /// because the MCP helper's `get_transcript(format: "srt")` serves the
    /// same bytes; keeping one implementation is what makes "export from
    /// the app" and "fetch over MCP" agree. `TranscriptExporterTests` pins
    /// the format from this side.
    static func srtBody(for segments: [TranscriptSegment],
                        names: [String: String] = [:]) -> String {
        TranscriptFormatter.srt(segments: segments, names: names)
    }
}
