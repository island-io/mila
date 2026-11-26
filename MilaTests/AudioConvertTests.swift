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
        // is finalized) before we read the file back.
        try {
            let file = try AVAudioFile(forWriting: wavURL, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = makeBuffer(format: format, sineHz: 440, frames: 32_000)
            try file.write(from: buffer)
        }()

        // Every frame. This used to allow a shortfall, blamed on the writer
        // not flushing its last buffer; the frames were on disk all along, and
        // it was the single read that stopped short (#376, see
        // `test_whisper_wav_round_trips_every_frame`).
        let samples = try AudioConvert.loadAsWhisperSamples(url: wavURL)
        XCTAssertEqual(samples.count, 32_000)
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

    /// The whole loader, on a real file: a 25 s WAV written by
    /// `writeWhisperWAV` comes back with every frame, whole and by range. It
    /// used to come back 640 frames short (399,360 = 390 × 1024): the file
    /// held all 400,000 — header, payload, `AVAudioFile.length` and
    /// `WAVReader` all said so on CI — but one `read(into:)` stopped at the
    /// last whole block of 1024 (#376). The `readFrames` tests below pin the
    /// loop itself, without a file.
    func test_whisper_wav_round_trips_every_frame() throws {
        let frames = 400_000
        let written = (0..<frames).map { 0.3 * Float(sin(Double($0) / 10)) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wav-roundtrip-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioConvert.writeWhisperWAV(samples: written, to: url)

        let whole = try AudioConvert.loadAsWhisperSamples(url: url)
        XCTAssertEqual(whole.count, frames)
        XCTAssertEqual(whole.suffix(640), written.suffix(640), "the end of the audio, not just its length")

        let ranged = try AudioConvert.loadAsWhisperSamples(url: url, from: 0, to: 25)
        XCTAssertEqual(ranged.count, frames)
    }

    /// What `AVAudioFile` does with a WAV: a read asked for N frames returns
    /// only the whole blocks of 1024, and the rest on the next call. Both
    /// channels of a deinterleaved buffer must come back whole and in order.
    func test_readFrames_keeps_reading_after_a_short_read() throws {
        let source = BlockReader(frames: 400_000, channels: 2)
        let buffer = try XCTUnwrap(AudioConvert.readFrames(
            count: 400_000, format: source.format, atEnd: { source.atEnd }, read: source.read))

        XCTAssertEqual(source.calls, 2, "399,360 frames, then the last 640")
        XCTAssertEqual(Int(buffer.frameLength), 400_000)
        for channel in 0..<2 {
            let read = Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: 400_000))
            XCTAssertEqual(read, source.data[channel], "channel \(channel)")
        }
    }

    /// A later read only adds to the first one, so its failure must not turn
    /// a load that one read used to complete into an error.
    func test_readFrames_keeps_the_first_read_when_a_later_read_fails() throws {
        let source = BlockReader(frames: 10_000, channels: 1)
        source.failOnCall = 2
        let buffer = try XCTUnwrap(AudioConvert.readFrames(
            count: 10_000, format: source.format, atEnd: { source.atEnd }, read: source.read))
        XCTAssertEqual(Int(buffer.frameLength), 9_216, "the 9 whole blocks the first read returned")
    }

    func test_readFrames_throws_when_the_first_read_fails() {
        let source = BlockReader(frames: 10_000, channels: 1)
        source.failOnCall = 1
        XCTAssertThrowsError(try AudioConvert.readFrames(
            count: 10_000, format: source.format, atEnd: { source.atEnd }, read: source.read))
    }

    /// A read that returns nothing ends the loop instead of spinning on it.
    func test_readFrames_stops_at_an_empty_read() throws {
        let source = BlockReader(frames: 10_000, channels: 1)
        source.emptyAfterFirstCall = true
        let buffer = try XCTUnwrap(AudioConvert.readFrames(
            count: 10_000, format: source.format, atEnd: { source.atEnd }, read: source.read))
        XCTAssertEqual(Int(buffer.frameLength), 9_216)
        XCTAssertEqual(source.calls, 2)
    }

    func test_readFrames_returns_nil_for_nothing_to_read() throws {
        let source = BlockReader(frames: 0, channels: 1)
        XCTAssertNil(try AudioConvert.readFrames(
            count: 0, format: source.format, atEnd: { source.atEnd }, read: source.read))
        XCTAssertEqual(source.calls, 0)
    }

    // MARK: - Helpers

    /// Stands in for `AVAudioFile.read(into:frameCount:)` as it behaves on a
    /// WAV: asked for 1024 frames or more, it fills only whole blocks of 1024
    /// and leaves the rest for the next call.
    private final class BlockReader {
        let format: AVAudioFormat
        let data: [[Float]]
        private var position = 0
        private(set) var calls = 0
        var failOnCall: Int?
        var emptyAfterFirstCall = false

        init(frames: Int, channels: Int) {
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: AVAudioChannelCount(channels), interleaved: false)!
            data = (0..<channels).map { channel in
                (0..<frames).map { Float(channel * 1_000_000 + $0) }
            }
        }

        var atEnd: Bool { position >= (data.first?.count ?? 0) }

        func read(_ buffer: AVAudioPCMBuffer, _ frameCount: AVAudioFrameCount) throws {
            calls += 1
            if calls == failOnCall { throw NSError(domain: "BlockReader", code: calls) }
            var count = min(Int(frameCount), (data.first?.count ?? 0) - position)
            if count >= 1024 { count -= count % 1024 }
            if emptyAfterFirstCall && calls > 1 { count = 0 }
            for (channel, samples) in data.enumerated() {
                samples.withUnsafeBufferPointer {
                    buffer.floatChannelData![channel].update(from: $0.baseAddress! + position, count: count)
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            position += count
        }
    }

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
