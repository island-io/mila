import XCTest
import AVFoundation
@testable import IslandWhisper

final class AudioMeterTests: XCTestCase {

    func test_silent_buffer_produces_zero_level() {
        let buffer = makeBuffer(amplitude: 0)
        let level = AudioMeter.level(from: buffer)
        XCTAssertEqual(level, 0, accuracy: 0.01)
    }

    func test_full_scale_sine_reads_as_high_level() {
        // A unit-amplitude sine has RMS = 1/√2 ≈ 0.707, which the dB
        // mapping in AudioMeter pegs at ~0.95 on the 0…1 scale.
        let buffer = makeBuffer(amplitude: 1.0)
        let level = AudioMeter.level(from: buffer)
        XCTAssertGreaterThan(level, 0.85)
        XCTAssertLessThanOrEqual(level, 1.0)
    }

    func test_quiet_buffer_is_below_loud_buffer() {
        let quiet = AudioMeter.level(from: makeBuffer(amplitude: 0.05))
        let loud = AudioMeter.level(from: makeBuffer(amplitude: 0.8))
        XCTAssertLessThan(quiet, loud)
        XCTAssertGreaterThan(loud, 0.5)
    }

    private func makeBuffer(amplitude: Float, frames: AVAudioFrameCount = 1600) -> AVAudioPCMBuffer {
        let format = WhisperAudioFormat.pcmFloat32
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        if let ptr = buffer.floatChannelData?[0] {
            for i in 0..<Int(frames) {
                let phase = 2.0 * Float.pi * 440.0 * Float(i) / Float(format.sampleRate)
                ptr[i] = sin(phase) * amplitude
            }
        }
        return buffer
    }
}
