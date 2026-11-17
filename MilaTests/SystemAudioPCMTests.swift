import XCTest
import AVFoundation
import CoreMedia
@testable import Mila

final class SystemAudioPCMTests: XCTestCase {
    func test_copy_preserves_mono_and_both_stereo_layouts() throws {
        for channels: AVAudioChannelCount in [1, 2] {
            for interleaved in [false, true] {
                let input = try makePCM(channels: channels, interleaved: interleaved)
                let sample = try makeSample(input)
                let output = try XCTUnwrap(SystemAudioPCM.buffer(from: sample))
                XCTAssertEqual(output.frameLength, input.frameLength)
                XCTAssertEqual(output.format, input.format)
                let expected = UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList)
                let actual = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
                XCTAssertEqual(actual.count, expected.count)
                for index in 0..<expected.count {
                    let bytes = Int(expected[index].mDataByteSize)
                    XCTAssertEqual(actual[index].mDataByteSize, expected[index].mDataByteSize)
                    XCTAssertEqual(Data(bytes: try XCTUnwrap(actual[index].mData), count: bytes),
                                   Data(bytes: try XCTUnwrap(expected[index].mData), count: bytes))
                }
                // Reusing the producer's memory must not change delivered audio.
                memset(try XCTUnwrap(expected[0].mData), 0, Int(expected[0].mDataByteSize))
                XCTAssertEqual(AudioConvert.samples(from: output), Array(repeating: 0.25, count: 32))
            }
        }
    }

    func test_not_ready_missing_and_empty_packets_are_rejected() throws {
        let input = try makePCM(channels: 1, interleaved: false)
        let missing = try makeSample(input, attachData: false)
        XCTAssertNil(SystemAudioPCM.buffer(from: missing))
        XCTAssertEqual(rejection(of: missing), .dataNotReady)
        XCTAssertEqual(CMSampleBufferSetDataReady(missing), noErr)
        XCTAssertNil(SystemAudioPCM.buffer(from: missing))
        // Ready but with no data behind it: only the Core Media copy can tell.
        guard case .some(.copyFailed) = rejection(of: missing) else {
            return XCTFail("expected copyFailed, got \(String(describing: rejection(of: missing)))")
        }
        let empty = try makeSample(input, attachData: false, frames: 0)
        XCTAssertEqual(CMSampleBufferSetDataReady(empty), noErr)
        XCTAssertNil(SystemAudioPCM.buffer(from: empty))
        XCTAssertEqual(rejection(of: empty), .noFrames)
    }

    /// The destination buffer is sized from the packet's own frame count, so
    /// that count is capped (2 s at the packet's rate) BEFORE allocating —
    /// not just at Int32.max, which would still let a corrupt header size a
    /// multi-gigabyte allocation on the sample queue.
    func test_oversized_packets_are_rejected_before_allocating() throws {
        let input = try makePCM(channels: 1, interleaved: false)   // 16 kHz
        let limit = try XCTUnwrap(SystemAudioPCM.maxFrames(sampleRate: 16_000))
        XCTAssertEqual(limit, 32_000)
        for frames in [limit + 1, 10_000_000] {
            let sample = try makeSample(input, attachData: false, frames: frames)
            XCTAssertEqual(CMSampleBufferSetDataReady(sample), noErr)
            XCTAssertEqual(rejection(of: sample), .tooManyFrames(frames, limit: limit))
        }
        // A packet exactly at the cap gets past the size check (and then fails
        // the copy only because this fixture has no data attached).
        let atLimit = try makeSample(input, attachData: false, frames: limit)
        XCTAssertEqual(CMSampleBufferSetDataReady(atLimit), noErr)
        guard case .some(.copyFailed) = rejection(of: atLimit) else {
            return XCTFail("a packet at the cap must not be refused as too large")
        }
    }

    func test_frame_cap_refuses_rates_no_stream_has() {
        XCTAssertEqual(SystemAudioPCM.maxFrames(sampleRate: 48_000), 96_000)
        for rate in [0, -16_000, .nan, .infinity, 2_000_000] as [Double] {
            XCTAssertNil(SystemAudioPCM.maxFrames(sampleRate: rate), "rate \(rate)")
        }
    }

    /// A per-buffer hot path: every drop is counted, the first is logged with
    /// its reason, and `stop()` reports and resets the tally for the next
    /// session. Good packets don't count.
    @MainActor
    func test_rejected_packets_are_counted_per_session() async throws {
        let recorder = SystemAudioRecorder()
        let input = try makePCM(channels: 1, interleaved: false)
        let bad = try makeSample(input, attachData: false)
        let good = try makeSample(input)
        for _ in 0..<3 { recorder.deliverSampleForTesting(bad) }
        recorder.deliverSampleForTesting(good)
        XCTAssertEqual(recorder.rejectedPacketCount, 3)
        await recorder.stop()
        XCTAssertEqual(recorder.rejectedPacketCount, 0)
    }

    /// The raw-AudioBuffer bound is a real check here, where the caller
    /// supplies the AudioBuffer. Reached from an AVAudioPCMBuffer it cannot
    /// fail (`mDataByteSize` there is derived from `frameLength`), which is
    /// why it is exercised directly rather than through a PCM buffer.
    func test_invalid_float_storage_is_rejected_before_reading_samples() {
        var values = [Float](repeating: 0.25, count: 32)
        values.withUnsafeMutableBytes { bytes in
            let valid = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress)
            var invalid = [valid, valid, valid]
            invalid[0].mData = nil
            invalid[1].mDataByteSize = 3
            invalid[2].mNumberChannels = 2
            for storage in invalid {
                let result: Bool? = AudioConvert.withFloatChannel(from: storage, frameCount: 32, stride: 1) { _, _, _ in
                    XCTFail("Malformed storage must never reach a sample consumer")
                    return true
                }
                XCTAssertNil(result)
            }
            let overflow: Bool? = AudioConvert.withFloatChannel(from: valid, frameCount: Int.max, stride: 1) { _, _, _ in
                XCTFail("Overflowing extent must never reach a sample consumer")
                return true
            }
            XCTAssertNil(overflow)
            let actual = AudioConvert.withFloatChannel(from: valid, frameCount: 32, stride: 1) { data, frames, _ in
                Array(UnsafeBufferPointer(start: data, count: frames))
            }
            XCTAssertEqual(actual, Array(repeating: 0.25, count: 32))
        }
    }

    func test_channel_zero_meter_still_handles_planar_and_interleaved_stereo() throws {
        for interleaved in [false, true] {
            let input = try makePCM(channels: 2, interleaved: interleaved)
            XCTAssertEqual(AudioConvert.samples(from: input), Array(repeating: 0.25, count: 32))
            XCTAssertEqual(AudioMeter.level(from: input), (20 * log10(Float(0.25)) + 60) / 60, accuracy: 0.0001)
        }
        let empty = try makePCM(channels: 1, interleaved: false)
        empty.frameLength = 0
        XCTAssertTrue(AudioConvert.samples(from: empty).isEmpty)
        XCTAssertEqual(AudioMeter.level(from: empty), 0)
    }

    /// A constant fixture can't tell a strided copy from a wrong one; a ramp
    /// on channel 0 (and a different value on channel 1) pins order and stride.
    func test_interleaved_channel_zero_is_extracted_in_frame_order() throws {
        for channels: AVAudioChannelCount in [2, 3] {
            // More than two channels needs an explicit layout:
            // `AVAudioFormat(commonFormat:sampleRate:channels:interleaved:)`
            // returns nil above stereo.
            let layout = try XCTUnwrap(AVAudioChannelLayout(
                layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(channels)))
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       interleaved: true, channelLayout: layout)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
            buffer.frameLength = 50
            let storage = try XCTUnwrap(buffer.audioBufferList.pointee.mBuffers.mData)
                .assumingMemoryBound(to: Float.self)
            for frame in 0..<50 {
                for channel in 0..<Int(channels) {
                    storage[frame * Int(channels) + channel] = channel == 0 ? Float(frame) : -1
                }
            }
            XCTAssertEqual(AudioConvert.samples(from: buffer), (0..<50).map { Float($0) }, "\(channels) channels")
        }
    }

    /// Only Float32 storage may be viewed as Float; anything else reads as
    /// "no samples", never as reinterpreted bytes.
    func test_non_float_buffers_read_as_empty() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                 channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        XCTAssertTrue(AudioConvert.samples(from: buffer).isEmpty)
        XCTAssertEqual(AudioMeter.level(from: buffer), 0)
    }

    private func rejection(of sample: CMSampleBuffer) -> SystemAudioPCM.Rejection? {
        if case .failure(let rejection) = SystemAudioPCM.copy(from: sample) { return rejection }
        return nil
    }

    private func makePCM(channels: AVAudioChannelCount, interleaved: Bool) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16_000, channels: channels, interleaved: interleaved))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (index, entry) in list.enumerated() {
            let pointer = try XCTUnwrap(entry.mData).assumingMemoryBound(to: Float.self)
            for sample in 0..<(Int(entry.mDataByteSize) / MemoryLayout<Float>.size) {
                let channel = interleaved ? sample % Int(channels) : index
                pointer[sample] = channel == 0 ? 0.25 : -0.75
            }
        }
        return buffer
    }

    private func makeSample(_ pcm: AVAudioPCMBuffer, attachData: Bool = true,
                            frames: Int? = nil) throws -> CMSampleBuffer {
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: pcm.format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format), noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000),
                                       presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: try XCTUnwrap(format), sampleCount: frames ?? Int(pcm.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
        let result = try XCTUnwrap(sample)
        if attachData {
            XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(result,
                blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: 0, bufferList: pcm.audioBufferList), noErr)
            XCTAssertEqual(CMSampleBufferSetDataReady(result), noErr)
        }
        return result
    }
}
