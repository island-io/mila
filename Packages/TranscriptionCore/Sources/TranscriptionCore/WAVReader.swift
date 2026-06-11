import Foundation

/// Pure-Swift WAV file reader. Parses 16-bit/32-bit PCM and IEEE float WAV files.
/// No AVFoundation dependency — works on Linux.
public enum WAVReader {

    public enum Error: Swift.Error, LocalizedError {
        case invalidFormat(String)

        public var errorDescription: String? {
            switch self {
            case .invalidFormat(let reason):
                return "Invalid WAV format: \(reason)"
            }
        }
    }

    /// Load audio samples from a WAV file, returning mono 16 kHz Float32 samples.
    ///
    /// - If the file is stereo (or more), channels are downmixed to mono by averaging.
    /// - If the sample rate differs from 16 kHz, linear interpolation resampling is applied.
    public static func loadSamples(url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else {
            throw Error.invalidFormat("File too small to contain a valid WAV header")
        }

        // RIFF header
        guard data.readString(offset: 0, length: 4) == "RIFF" else {
            throw Error.invalidFormat("Missing RIFF header")
        }
        guard data.readString(offset: 8, length: 4) == "WAVE" else {
            throw Error.invalidFormat("Missing WAVE identifier")
        }

        // Find fmt chunk
        guard let fmtChunk = findChunk(id: "fmt ", in: data, startOffset: 12) else {
            throw Error.invalidFormat("Missing fmt chunk")
        }

        let fmtData = fmtChunk.data
        guard fmtData.count >= 16 else {
            throw Error.invalidFormat("fmt chunk too small")
        }

        let audioFormat = fmtData.readUInt16LE(offset: 0)
        let channels = fmtData.readUInt16LE(offset: 2)
        let sampleRate = fmtData.readUInt32LE(offset: 4)
        // bytes 8-11: byte rate (skip)
        // bytes 12-13: block align (skip)
        let bitsPerSample = fmtData.readUInt16LE(offset: 14)

        guard audioFormat == 1 || audioFormat == 3 else {
            throw Error.invalidFormat(
                "Unsupported audio format \(audioFormat). Only PCM (1) and IEEE float (3) are supported")
        }
        guard bitsPerSample == 16 || bitsPerSample == 32 else {
            throw Error.invalidFormat(
                "Unsupported bits per sample: \(bitsPerSample). Only 16 and 32 are supported")
        }
        guard channels >= 1 else {
            throw Error.invalidFormat("Invalid channel count: \(channels)")
        }

        // Find data chunk
        guard let dataChunk = findChunk(id: "data", in: data, startOffset: 12) else {
            throw Error.invalidFormat("Missing data chunk")
        }

        let rawData = dataChunk.data
        if rawData.isEmpty {
            return []
        }

        // Decode samples per channel
        let interleavedSamples: [Float]
        if audioFormat == 3 && bitsPerSample == 32 {
            interleavedSamples = decodeFloat32(rawData)
        } else if audioFormat == 1 && bitsPerSample == 16 {
            interleavedSamples = decodeInt16(rawData)
        } else if audioFormat == 1 && bitsPerSample == 32 {
            interleavedSamples = decodeInt32(rawData)
        } else {
            throw Error.invalidFormat(
                "Unsupported combination: format=\(audioFormat), bits=\(bitsPerSample)")
        }

        // Downmix to mono if needed
        let monoSamples: [Float]
        let channelCount = Int(channels)
        if channelCount == 1 {
            monoSamples = interleavedSamples
        } else {
            let frameCount = interleavedSamples.count / channelCount
            monoSamples = (0..<frameCount).map { frame in
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += interleavedSamples[frame * channelCount + ch]
                }
                return sum / Float(channelCount)
            }
        }

        // Resample to 16 kHz if needed
        let targetRate: UInt32 = 16000
        if sampleRate == targetRate {
            return monoSamples
        }

        return resample(monoSamples, from: sampleRate, to: targetRate)
    }

    // MARK: - Chunk Scanner

    private struct ChunkInfo {
        let data: Data
    }

    /// Scan WAV chunks starting at `startOffset`, looking for a chunk with the given 4-char ID.
    /// Handles 2-byte alignment padding between chunks.
    private static func findChunk(id: String, in data: Data, startOffset: Int) -> ChunkInfo? {
        var offset = startOffset
        while offset + 8 <= data.count {
            let chunkID = data.readString(offset: offset, length: 4)
            let chunkSize = Int(data.readUInt32LE(offset: offset + 4))
            let chunkDataStart = offset + 8

            if chunkID == id {
                let available = min(chunkSize, data.count - chunkDataStart)
                let chunkData = data.subdata(in: chunkDataStart..<(chunkDataStart + available))
                return ChunkInfo(data: chunkData)
            }

            // Move to next chunk, accounting for 2-byte alignment padding
            let nextOffset = chunkDataStart + chunkSize
            offset = nextOffset % 2 == 0 ? nextOffset : nextOffset + 1
        }
        return nil
    }

    // MARK: - Sample Decoders

    private static func decodeFloat32(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let src = raw.baseAddress!
            samples.withUnsafeMutableBufferPointer { dst in
                memcpy(dst.baseAddress!, src, count * MemoryLayout<Float>.size)
            }
        }
        return samples
    }

    private static func decodeInt16(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Int16>.size
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                var value: Int16 = 0
                memcpy(&value, raw.baseAddress! + i * MemoryLayout<Int16>.size, MemoryLayout<Int16>.size)
                samples[i] = Float(value) / Float(Int16.max)
            }
        }
        return samples
    }

    private static func decodeInt32(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Int32>.size
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                var value: Int32 = 0
                memcpy(&value, raw.baseAddress! + i * MemoryLayout<Int32>.size, MemoryLayout<Int32>.size)
                samples[i] = Float(value) / Float(Int32.max)
            }
        }
        return samples
    }

    // MARK: - Resampling

    /// Linear interpolation resampling from one sample rate to another.
    private static func resample(_ samples: [Float], from sourceRate: UInt32, to targetRate: UInt32) -> [Float] {
        guard !samples.isEmpty else { return [] }

        let ratio = Double(sourceRate) / Double(targetRate)
        let outputCount = Int(Double(samples.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIndex = Double(i) * ratio
            let lower = Int(srcIndex)
            let frac = Float(srcIndex - Double(lower))

            if lower + 1 < samples.count {
                output[i] = samples[lower] * (1.0 - frac) + samples[lower + 1] * frac
            } else {
                output[i] = samples[min(lower, samples.count - 1)]
            }
        }
        return output
    }
}

// MARK: - Data Extensions

extension Data {
    func readUInt16LE(offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        var value: UInt16 = 0
        withUnsafeBytes { raw in
            memcpy(&value, raw.baseAddress! + offset, MemoryLayout<UInt16>.size)
        }
        return UInt16(littleEndian: value)
    }

    func readUInt32LE(offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        withUnsafeBytes { raw in
            memcpy(&value, raw.baseAddress! + offset, MemoryLayout<UInt32>.size)
        }
        return UInt32(littleEndian: value)
    }

    func readString(offset: Int, length: Int) -> String? {
        guard offset + length <= count else { return nil }
        let sub = subdata(in: offset..<(offset + length))
        return String(data: sub, encoding: .ascii)
    }
}
