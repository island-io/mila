import Foundation
import AVFoundation

/// Writes the leading part of a recording's audio to a new file — the audio
/// half of "End Conversation Here" (island-io/mila#357). The caller
/// (`RecordingStore.trimAudio`) writes to a temporary file next to the
/// original and swaps it in only once this has succeeded, so a failure here
/// never touches the recording's audio.
///
/// Only the two formats Mila itself stores are rewritten: the live-capture
/// `.wav` and the compressed `.m4a` (`AudioCompressor`). Anything else is
/// reported as unsupported rather than guessed at.
enum AudioTrimmer {
    enum TrimError: Error {
        case unsupportedFormat
        case makeBuffer
    }

    static let supportedExtensions: Set<String> = ["wav", "m4a"]

    static func supports(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Write the first `seconds` of `source` to `destination` (whose
    /// extension must match the source's, since `AVAudioFile` picks the
    /// container from it). Returns the written length in seconds, or nil —
    /// writing nothing — when `seconds` is at or past the end of the audio,
    /// so there is nothing to cut.
    static func writePrefix(of source: URL, seconds: Double, to destination: URL) async throws -> Double? {
        try await Task.detached(priority: .userInitiated) {
            try AudioTrimmer.writePrefixSync(of: source, seconds: seconds, to: destination)
        }.value
    }

    /// Synchronous body of `writePrefix`. A separate function so the output
    /// `AVAudioFile` is released — which is what finalises its header — before
    /// the caller moves the file into place.
    private static func writePrefixSync(of source: URL, seconds: Double, to destination: URL) throws -> Double? {
        guard supports(source), seconds.isFinite, seconds > 0 else { throw TrimError.unsupportedFormat }
        // A WAV recovered after a crash can still carry an unfinalized header
        // (`data` size 0), which AVAudioFile reads as an empty file — the cut
        // would then look like "nothing to trim". Repair it first, as the
        // launch recovery sweep does; a finalized header is left untouched.
        if source.pathExtension.lowercased() == "wav" {
            _ = WAVHeaderRepair.repairIfNeeded(at: source)
        }
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard format.sampleRate > 0 else { throw TrimError.unsupportedFormat }
        let requested = (seconds * format.sampleRate).rounded(.down)
        // The audio, as decoded, already ends at or before `seconds`. The
        // caller reports this to the user rather than treating it as done.
        guard requested < Double(input.length) else { return nil }
        let endFrame = AVAudioFramePosition(requested)

        let settings: [String: Any]
        if source.pathExtension.lowercased() == "m4a" {
            // Same encoder family `AudioCompressor` produces. No bit-rate key:
            // a Voice Memos import can be 48 kHz stereo, and a fixed rate
            // that suits Mila's 16 kHz mono captures may be invalid there —
            // the encoder's default is always valid.
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount
            ]
        } else {
            // A WAV keeps its exact on-disk sample format.
            settings = input.fileFormat.settings
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let output = try AVAudioFile(forWriting: destination,
                                     settings: settings,
                                     commonFormat: format.commonFormat,
                                     interleaved: format.isInterleaved)
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else {
            throw TrimError.makeBuffer
        }
        // Bounded by frame position, as in `AudioCompressor`: `read` throws on
        // an attempt past the end of the file.
        var written: AVAudioFramePosition = 0
        while input.framePosition < endFrame {
            let remaining = AVAudioFrameCount(endFrame - input.framePosition)
            try input.read(into: buffer, frameCount: min(chunk, remaining))
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
            written += AVAudioFramePosition(buffer.frameLength)
        }
        return Double(written) / format.sampleRate
    }
}
