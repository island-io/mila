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

    /// A 25 s recording written by `writeWhisperWAV` and read back by
    /// `loadAsWhisperSamples` came back 640 frames short on CI's macOS 26
    /// image (#376) — 399,360 = 390 × 1024. Measures every step separately
    /// so the message says which side loses the frames.
    func test_whisper_wav_round_trips_every_frame() throws {
        let frames = 400_000
        let samples = (0..<frames).map { 0.3 * Float(sin(Double($0) / 10)) }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wav-roundtrip-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func dataFrames(_ url: URL) -> Int {
            guard let bytes = try? [UInt8](Data(contentsOf: url)), bytes.count >= 12 else { return -1 }
            func u32(_ o: Int) -> Int {
                Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
            }
            var offset = 12
            while offset + 8 <= bytes.count {
                let size = u32(offset + 4)
                if bytes[offset..<offset + 4].elementsEqual("data".utf8) {
                    return size / 4 * 1_000_000 + (bytes.count - offset - 8) / 4
                }
                offset += 8 + size + (size & 1)
            }
            return -2
        }
        var report: [String] = []

        let plain = dir.appendingPathComponent("plain.wav")
        try AudioConvert.writeWhisperWAV(samples: samples, to: plain)
        report.append("written(header*1e6+payload)=\(dataFrames(plain))")
        report.append("AVAudioFile.length=\((try? AVAudioFile(forReading: plain).length) ?? -1)")
        report.append("WAVReader=\((try? WAVReader.loadSamples(url: plain).count) ?? -1)")
        let loaded = try AudioConvert.loadAsWhisperSamples(url: plain)
        report.append("loadAsWhisperSamples=\(loaded.count)")
        if let file = try? AVAudioFile(forReading: plain),
           let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)) {
            var total = 0
            while file.framePosition < file.length {
                try file.read(into: buffer)
                if buffer.frameLength == 0 { break }
                total += Int(buffer.frameLength)
            }
            report.append("readLoop=\(total)")
        }

        let pooled = dir.appendingPathComponent("pooled.wav")
        try autoreleasepool { try AudioConvert.writeWhisperWAV(samples: samples, to: pooled) }
        report.append("pooledWrite=\(dataFrames(pooled))")

        if #available(macOS 15.0, *) {
            let closed = dir.appendingPathComponent("closed.wav")
            let format = WhisperAudioFormat.pcmFloat32
            let file = try AVAudioFile(forWriting: closed, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: frames) }
            try file.write(from: buffer)
            report.append("beforeClose=\(dataFrames(closed))")
            file.close()
            report.append("closedWrite=\(dataFrames(closed))")
        }

        let message = report.joined(separator: " ")
        print("[wav-roundtrip] \(message)")
        XCTAssertEqual(loaded.count, frames, message)
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

/// `AudioSignal.isSilent` is the "did capture produce anything at all?"
/// predicate that keeps a zero-frame session off the network (issue #147). It
/// deliberately is NOT a loudness gate — see the quiet-audio case.
final class AudioSignalTests: XCTestCase {

    func test_emptyBufferIsSilent() {
        XCTAssertTrue(AudioSignal.isSilent([]))
    }

    func test_allZerosIsSilent() {
        XCTAssertTrue(AudioSignal.isSilent([Float](repeating: 0, count: 48_000)))
    }

    func test_oneNonZeroSampleIsNotSilent() {
        var samples = [Float](repeating: 0, count: 48_000)
        samples[47_999] = -0.000_01
        XCTAssertFalse(AudioSignal.isSilent(samples),
                       "the predicate must not discard real, quiet audio — that's a separate, louder threshold")
    }

    func test_normalAudioIsNotSilent() {
        let samples = (0..<1_600).map { Float(sin(Double($0) * 0.1)) * 0.3 }
        XCTAssertFalse(AudioSignal.isSilent(samples))
    }
}
