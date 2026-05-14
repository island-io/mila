import XCTest
import AVFoundation
import TranscriptionCore
@testable import IslandWhisper

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
