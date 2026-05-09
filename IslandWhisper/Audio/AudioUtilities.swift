import Foundation
import AVFoundation
import Accelerate

/// The format Whisper expects: 16kHz, mono, 32-bit float PCM.
enum WhisperAudioFormat {
    static let sampleRate: Double = 16_000
    static let channels: AVAudioChannelCount = 1

    static var pcmFloat32: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: sampleRate,
                      channels: channels,
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
