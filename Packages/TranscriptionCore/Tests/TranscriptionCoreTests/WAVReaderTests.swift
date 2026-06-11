import XCTest
@testable import TranscriptionCore

final class WAVReaderTests: XCTestCase {

    func test_reads_valid_16khz_mono_wav() throws {
        let samples = makeSineWav(hz: 440, durationSeconds: 1.0, sampleRate: 16000)
        let url = try writeWav(samples: samples, sampleRate: 16000, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try WAVReader.loadSamples(url: url)
        XCTAssertEqual(loaded.count, 16000, accuracy: 10)
        XCTAssertGreaterThan(loaded.map { abs($0) }.max() ?? 0, 0.3)
    }

    func test_rejects_non_wav_file() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-wav-\(UUID()).txt")
        FileManager.default.createFile(atPath: url.path, contents: "hello".data(using: .utf8))
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try WAVReader.loadSamples(url: url))
    }

    func test_empty_wav_returns_empty_samples() throws {
        let url = try writeWav(samples: [], sampleRate: 16000, channels: 1)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try WAVReader.loadSamples(url: url)
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - Helpers

    private func makeSineWav(hz: Double, durationSeconds: Double, sampleRate: Int) -> [Float] {
        let count = Int(Double(sampleRate) * durationSeconds)
        return (0..<count).map { i in
            Float(sin(2.0 * .pi * hz * Double(i) / Double(sampleRate)) * 0.6)
        }
    }

    private func writeWav(samples: [Float], sampleRate: UInt32, channels: UInt16) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID()).wav")
        var data = Data()
        let dataSize = UInt32(samples.count * MemoryLayout<Float>.size)
        let fileSize = 36 + dataSize

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(3).littleEndian) { Array($0) }) // IEEE float
        data.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        let byteRate = sampleRate * UInt32(channels) * 4
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        let blockAlign = channels * 4
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(32).littleEndian) { Array($0) })
        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        for sample in samples {
            data.append(contentsOf: withUnsafeBytes(of: sample) { Array($0) })
        }
        try data.write(to: url)
        return url
    }
}
