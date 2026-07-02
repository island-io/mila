import XCTest
import AVFoundation
import TranscriptionCore
@testable import Mila

final class AudioConvertTests: XCTestCase {

    func test_buffer_already_in_whisper_format_is_returned_as_is() throws {
        let buffer = makeBuffer(format: WhisperAudioFormat.pcmFloat32, sineHz: 440, frames: 1600)

        let converted = try AudioConvert.toWhisperFormat(buffer)

        XCTAssertEqual(converted.format.sampleRate, WhisperAudioFormat.sampleRate)
        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertEqual(Int(converted.frameLength), 1600)
    }

    func test_stereo_48k_buffer_is_downmixed_to_mono_16k() throws {
        let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 48_000,
                                         channels: 2,
                                         interleaved: false)!
        let buffer = makeBuffer(format: stereoFormat, sineHz: 440, frames: 4_800)

        let converted = try AudioConvert.toWhisperFormat(buffer)

        XCTAssertEqual(converted.format.sampleRate, 16_000)
        XCTAssertEqual(converted.format.channelCount, 1)
        let expected = Int(4_800 * 16_000 / 48_000)
        XCTAssertEqual(Int(converted.frameLength), expected, accuracy: 64)
    }

    func test_samples_extracts_mono_channel_correctly() {
        let buffer = makeBuffer(format: WhisperAudioFormat.pcmFloat32, sineHz: 100, frames: 800)
        let samples = AudioConvert.samples(from: buffer)
        XCTAssertEqual(samples.count, 800)
        XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.5)
    }

    func test_load_as_whisper_samples_round_trips_a_wav_file() throws {
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-convert-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let format = WhisperAudioFormat.pcmFloat32
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        // Write in a nested scope so the writer is deallocated (and the header
        // is finalized) before we read the file back. AVAudioFile may not flush
        // its very last buffer on deinit, so we write more than we need and
        // assert on a generous lower bound.
        try {
            let file = try AVAudioFile(forWriting: wavURL, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = makeBuffer(format: format, sineHz: 440, frames: 32_000)
            try file.write(from: buffer)
        }()

        let samples = try AudioConvert.loadAsWhisperSamples(url: wavURL)
        XCTAssertGreaterThan(samples.count, 24_000,
                             "Expected most of the 32k samples to round trip")
        XCTAssertLessThanOrEqual(samples.count, 32_000)
        XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.4)
    }

    func test_load_as_whisper_samples_returns_empty_for_zero_length_file() throws {
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let format = WhisperAudioFormat.pcmFloat32
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        try {
            _ = try AVAudioFile(forWriting: wavURL, settings: settings,
                                commonFormat: .pcmFormatFloat32, interleaved: false)
        }()
        let samples = try AudioConvert.loadAsWhisperSamples(url: wavURL)
        XCTAssertTrue(samples.isEmpty)
    }

    // MARK: - StreamingWhisperConverter

    /// Regression: sample-rate conversion is stateful. The old pattern —
    /// a fresh `AVAudioConverter` per tap buffer (`toWhisperFormat` in a
    /// loop) — restarts the resampler filter at every chunk edge, which
    /// dips the output toward zero at each boundary (~every 85ms of every
    /// recording from a 48kHz mic). A DC (constant 1.0) input makes those
    /// dips easy to detect: through the session-scoped streaming converter
    /// the settled output must stay flat across all chunk boundaries.
    func test_streaming_converter_keeps_resampler_state_across_buffers() throws {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 48_000,
                                        channels: 1,
                                        interleaved: false)!
        let converter = try XCTUnwrap(StreamingWhisperConverter(inputFormat: inputFormat))

        var output: [Float] = []
        for _ in 0..<8 {
            let chunk = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 4096)!
            chunk.frameLength = 4096
            if let ptr = chunk.floatChannelData?[0] {
                for i in 0..<4096 { ptr[i] = 1.0 }
            }
            let converted = try converter.convert(chunk)
            output.append(contentsOf: AudioConvert.samples(from: converted))
        }

        // 8 × 4096 @ 48k → ~10.9k frames @ 16k (minus a little converter
        // latency). Skip the legitimate initial filter ramp, then require
        // the DC level to hold across every boundary.
        XCTAssertGreaterThan(output.count, 8_000, "converter should emit most frames")
        let settled = output.dropFirst(400)
        let minValue = settled.min() ?? 0
        XCTAssertGreaterThan(minValue, 0.95,
                             "DC input must stay flat across buffer boundaries — a dip means the resampler state was reset mid-stream (min=\(minValue))")
    }

    func test_streaming_converter_passes_through_whisper_shaped_buffers() throws {
        let converter = try XCTUnwrap(
            StreamingWhisperConverter(inputFormat: WhisperAudioFormat.pcmFloat32))
        let buffer = makeBuffer(format: WhisperAudioFormat.pcmFloat32, sineHz: 440, frames: 1600)
        let converted = try converter.convert(buffer)
        XCTAssertTrue(converted === buffer,
                      "Pass-through must return the same instance (documented contract — callers copy before mutating)")
    }

    // MARK: - Helpers

    private func makeBuffer(format: AVAudioFormat,
                            sineHz: Double,
                            frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let sampleRate = format.sampleRate
        let twoPi = 2.0 * Double.pi
        for ch in 0..<Int(format.channelCount) {
            guard let ptr = buffer.floatChannelData?[ch] else { continue }
            for i in 0..<Int(frames) {
                let phase = twoPi * sineHz * Double(i) / sampleRate
                ptr[i] = Float(sin(phase) * 0.6)
            }
        }
        return buffer
    }
}
