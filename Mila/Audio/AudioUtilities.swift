import Foundation
import AVFoundation
import Accelerate
import TranscriptionCore

extension WhisperAudioFormat {
    static var pcmFloat32: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: sampleRate,
                      channels: AVAudioChannelCount(channelCount),
                      interleaved: false)!
    }
}

enum AudioConvert {
    /// Convert any AVAudioPCMBuffer to mono 16kHz Float32 PCM, returning a new buffer.
    static func toWhisperFormat(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let target = WhisperAudioFormat.pcmFloat32
        if buffer.format.sampleRate == target.sampleRate &&
            buffer.format.channelCount == target.channelCount &&
            buffer.format.commonFormat == .pcmFormatFloat32 {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: target) else {
            throw NSError(domain: "AudioConvert", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to create AVAudioConverter."])
        }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else {
            throw NSError(domain: "AudioConvert", code: 2)
        }

        var error: NSError?
        var fed = false
        let status = converter.convert(to: output, error: &error) { _, statusPointer in
            if fed {
                statusPointer.pointee = .endOfStream
                return nil
            }
            statusPointer.pointee = .haveData
            fed = true
            return buffer
        }

        if let error = error { throw error }
        if status == .error {
            throw NSError(domain: "AudioConvert", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Converter returned error."])
        }
        return output
    }

    /// Pull mono float samples out of a buffer (Whisper-shaped).
    static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: data[0], count: count))
    }

    /// Read a wav/aiff/m4a file and convert all of its samples to Whisper format.
    static func loadAsWhisperSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: totalFrames) else {
            return []
        }
        try file.read(into: inputBuffer)
        let converted = try toWhisperFormat(inputBuffer)
        return samples(from: converted)
    }

    /// Write 16 kHz mono float32 samples as an IEEE-float WAV. Used to
    /// hand the Python diarizer (soundfile/libsndfile) a readable file
    /// when the recording is a compressed .m4a it can't open.
    static func writeWhisperWAV(samples: [Float], to url: URL) throws {
        let format = WhisperAudioFormat.pcmFloat32
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(max(1, samples.count))) else {
            throw NSError(domain: "AudioConvert", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate WAV buffer."])
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                if let base = src.baseAddress { channel.update(from: base, count: samples.count) }
            }
        }
        let file = try AVAudioFile(forWriting: url,
                                   settings: format.settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: buffer)
    }
}

/// Stateful streaming variant of `AudioConvert.toWhisperFormat` for capture
/// sessions.
///
/// Sample-rate conversion is stateful: the resampler carries filter history
/// across buffers. `toWhisperFormat` builds a fresh `AVAudioConverter` per
/// call and flushes it with `.endOfStream` — correct for one-shot
/// (whole-file) conversion, wrong for a live tap: restarting the filter at
/// every ~85ms tap buffer zero-pads its history and independently rounds
/// the fractional frame ratio (48k→16k = 1365⅓ frames per 4096), leaving a
/// small waveform discontinuity at every buffer boundary of every recording
/// made from a non-16kHz device. One instance per capture session keeps the
/// filter warm across buffers; the only cost is that the last few samples of
/// filter latency are never flushed at stream end (a sub-millisecond tail,
/// vs. an artifact every 85ms).
///
/// NOT thread-safe: feed it from a single serial context (the AVAudioEngine
/// tap or the SCK sample-handler queue).
final class StreamingWhisperConverter {
    /// nil when the input is already whisper-shaped (pass-through).
    private let converter: AVAudioConverter?
    let inputFormat: AVAudioFormat

    /// Fails only if `AVAudioConverter` can't be built for `inputFormat`.
    init?(inputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
        let target = WhisperAudioFormat.pcmFloat32
        if inputFormat.sampleRate == target.sampleRate &&
            inputFormat.channelCount == target.channelCount &&
            inputFormat.commonFormat == .pcmFormatFloat32 {
            self.converter = nil
        } else if let converter = AVAudioConverter(from: inputFormat, to: target) {
            self.converter = converter
        } else {
            return nil
        }
    }

    /// Convert one buffer, retaining resampler state for the next call.
    /// Pass-through inputs return the SAME buffer instance — callers that
    /// mutate the result in place must copy first (same contract as
    /// `toWhisperFormat`).
    func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let converter else { return buffer }
        let target = WhisperAudioFormat.pcmFloat32
        let ratio = target.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputCapacity) else {
            throw NSError(domain: "AudioConvert", code: 2)
        }

        var error: NSError?
        var fed = false
        let status = converter.convert(to: output, error: &error) { _, statusPointer in
            if fed {
                // `.noDataNow`, NOT `.endOfStream`: the filter history must
                // stay alive for the next buffer — flushing here is exactly
                // the per-chunk restart this class exists to avoid.
                statusPointer.pointee = .noDataNow
                return nil
            }
            statusPointer.pointee = .haveData
            fed = true
            return buffer
        }

        if let error { throw error }
        if status == .error {
            throw NSError(domain: "AudioConvert", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Converter returned error."])
        }
        return output
    }
}

/// Computes a 0...1 RMS level from an audio buffer for VU meters.
enum AudioMeter {
    static func level(from buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let count = vDSP_Length(buffer.frameLength)
        var rms: Float = 0
        vDSP_rmsqv(data[0], 1, &rms, count)
        let avgPower = 20 * log10(max(rms, 0.000_001))
        let normalized = max(0, (avgPower + 60) / 60)
        return min(1, normalized)
    }
}
