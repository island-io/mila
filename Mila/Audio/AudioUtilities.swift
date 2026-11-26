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

    /// Hand `body` channel zero of a Float32 buffer as (pointer, frames, stride),
    /// or return nil — never trap — when there is nothing safe to read: a
    /// non-Float32 format, zero frames, or no storage behind the channel.
    /// Interleaved buffers keep every channel in one AudioBuffer, so channel
    /// zero is every `channelCount`-th sample (stride > 1).
    ///
    /// Reads go through the READ-ONLY `audioBufferList`. `mutableAudioBufferList`
    /// is for callers that rewrite the list (Core Audio copies, converters);
    /// fetching it on a read path turns every meter/sample read into a write
    /// of the buffer's list metadata.
    static func withFloatChannel<R>(from buffer: AVAudioPCMBuffer,
                                    _ body: (UnsafePointer<Float>, Int, Int) -> R) -> R? {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              frames > 0, frames <= Int(buffer.frameCapacity), channels > 0 else { return nil }
        let list = buffer.audioBufferList.pointee
        let interleaved = buffer.format.isInterleaved
        guard Int(list.mNumberBuffers) >= (interleaved ? 1 : channels) else { return nil }
        // `mBuffers` is the list's first AudioBuffer — channel zero's storage
        // in both layouts.
        return withFloatChannel(from: list.mBuffers, frameCount: frames,
                                stride: interleaved ? channels : 1, body)
    }

    /// Check a raw Float32 AudioBuffer against the extent the caller is about
    /// to read — channel count matches the stride, storage is non-nil, and
    /// `frameCount * stride` floats fit in `mDataByteSize` without overflow —
    /// before building any typed view over it.
    ///
    /// What the byte check does and doesn't buy: for an arbitrary AudioBuffer
    /// (the case the tests drive directly) it is a real bound. Reached from an
    /// AVAudioPCMBuffer it cannot fail — `audioBufferList` reports
    /// `mDataByteSize` derived from `frameLength`, and AVFAudio already
    /// refuses a `frameLength` past `frameCapacity` — so on that path it is
    /// consistency, not a check against the real allocation. The protection
    /// against reading past an allocation is upstream, where a packet's
    /// storage is COPIED into an AVAudioPCMBuffer sized from its own frame
    /// count (`SystemAudioPCM`), never adopted with a foreign byte count.
    static func withFloatChannel<R>(from storage: AudioBuffer, frameCount: Int, stride: Int,
                                    _ body: (UnsafePointer<Float>, Int, Int) -> R) -> R? {
        guard frameCount > 0, stride > 0, Int(storage.mNumberChannels) == stride,
              let data = storage.mData else { return nil }
        let (samples, sampleOverflow) = frameCount.multipliedReportingOverflow(by: stride)
        let (bytes, byteOverflow) = samples.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !sampleOverflow, !byteOverflow, bytes <= Int(storage.mDataByteSize) else { return nil }
        return body(UnsafePointer(data.assumingMemoryBound(to: Float.self)), frameCount, stride)
    }

    /// Pull channel-zero float samples (normally mono, Whisper-shaped).
    static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        withFloatChannel(from: buffer) { data, count, stride in
            if stride == 1 { return Array(UnsafeBufferPointer(start: data, count: count)) }
            // Interleaved: a strided copy of column 0 — one `count`-row,
            // 1-column submatrix of a `stride`-column matrix — with the same
            // vDSP stride handling `AudioMeter` uses, not a per-sample map.
            return [Float](unsafeUninitializedCapacity: count) { out, initialized in
                vDSP_mmov(data, out.baseAddress!, 1, vDSP_Length(count),
                          vDSP_Length(stride), 1)
                initialized = count
            }
        } ?? []
    }

    /// Read a wav/aiff/m4a file and convert all of its samples to Whisper format.
    static func loadAsWhisperSamples(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let inputBuffer = try readFrames(from: file, count: file.length) else { return [] }
        let converted = try toWhisperFormat(inputBuffer)
        return samples(from: converted)
    }

    /// Read `count` frames from `file`'s current position into one buffer,
    /// or nil when there is nothing to read. Callers clamp `count` to the
    /// file. See `readFrames(count:format:atEnd:read:)`.
    static func readFrames(from file: AVAudioFile, count: AVAudioFramePosition) throws -> AVAudioPCMBuffer? {
        try readFrames(count: count, format: file.processingFormat,
                       atEnd: { file.framePosition >= file.length },
                       read: { try file.read(into: $0, frameCount: $1) })
    }

    /// Fill one buffer with `count` frames from `read`, calling it again for
    /// whatever a call left out.
    ///
    /// One `AVAudioFile.read(into:frameCount:)` is not enough: it can return
    /// fewer frames than asked for before the end of the file. A single read
    /// of a 400,000-frame 16 kHz float WAV returns 399,360 — 390 whole blocks
    /// of 1024 — on macOS 26 and 27 alike, and a second read returns the
    /// other 640. With one read, a WAV recording lost whatever followed its
    /// last whole 1024-frame block (up to 64 ms), and its length came out
    /// short of its audio (#376).
    ///
    /// Bounded like the read loops in `AudioCompressor` and `AudioTrimmer`:
    /// it stops at `count`, at `atEnd`, or at a read that returns nothing,
    /// since `read` throws on an attempt past the end of the file. The first
    /// read's error is thrown; a LATER read's is not — those reads only add
    /// to what the first one returned, so a failed one leaves exactly what a
    /// single read returned before #376.
    static func readFrames(count: AVAudioFramePosition,
                           format: AVAudioFormat,
                           atEnd: () -> Bool,
                           read: (AVAudioPCMBuffer, AVAudioFrameCount) throws -> Void) throws -> AVAudioPCMBuffer? {
        guard count > 0, let total = AVAudioFrameCount(exactly: count),
              let whole = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else {
            return nil
        }
        try read(whole, total)
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard whole.frameLength < total, !atEnd(), bytesPerFrame > 0,
              let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total - whole.frameLength) else {
            return whole
        }
        while whole.frameLength < total, !atEnd() {
            let missing = total - whole.frameLength
            do {
                try read(chunk, missing)
            } catch {
                break
            }
            let got = min(chunk.frameLength, missing)
            guard got > 0 else { break }
            // Append the chunk after what `whole` already holds, buffer by
            // buffer (one per channel when deinterleaved, one in all when
            // interleaved — `mBytesPerFrame` is per buffer either way).
            let destination = UnsafeMutableAudioBufferListPointer(whole.mutableAudioBufferList)
            let source = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
            guard destination.count == source.count else { break }
            let offset = Int(whole.frameLength) * bytesPerFrame
            for index in 0..<destination.count {
                guard let to = destination[index].mData, let from = source[index].mData else { return whole }
                (to + offset).copyMemory(from: from, byteCount: Int(got) * bytesPerFrame)
            }
            whole.frameLength += got
        }
        return whole
    }

    /// Read only `[start, end)` seconds of a wav/aiff/m4a file and convert
    /// them to Whisper format, without decoding the rest of the recording.
    /// Used to re-transcribe the spans the live path missed (#355). Clamped
    /// to the file; an empty range returns `[]`.
    static func loadAsWhisperSamples(url: URL, from start: TimeInterval, to end: TimeInterval) throws -> [Float] {
        // A NaN or infinite bound would trap in the frame-count conversion.
        guard start.isFinite, end.isFinite, end > start else { return [] }
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        // Clamp in Double space BEFORE converting: a huge-but-finite bound
        // (seconds × rate past Int64) would trap in the integer conversion.
        let length = Double(file.length)
        let startFrame = AVAudioFramePosition(min(length, max(0, start * rate).rounded(.down)))
        let endFrame = AVAudioFramePosition(min(length, max(0, end * rate).rounded(.up)))
        guard endFrame > startFrame else { return [] }
        file.framePosition = startFrame
        guard let inputBuffer = try readFrames(from: file, count: endFrame - startFrame) else { return [] }
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

/// Predicates about a raw sample buffer, shared by every path that has to
/// decide "is there anything here at all?".
enum AudioSignal {
    /// True when a buffer carries no signal whatsoever: no samples, or nothing
    /// but exact digital silence.
    ///
    /// Deliberately the strictest possible test. It is NOT the "too quiet to
    /// be speech" gate — that's `TranscriptionService.minimumAudioPeak`, which
    /// only the batch path applies, because a quiet-but-real utterance is
    /// still worth transcribing. This one answers the narrower question "did
    /// capture produce anything?", which is safe to apply even to a 300ms live
    /// utterance: a live microphone, in a silent room, still delivers dither
    /// and noise, never a run of exact zeros.
    ///
    /// O(1) for real audio — `contains` returns at the first non-zero sample.
    static func isSilent(_ samples: [Float]) -> Bool {
        !samples.contains { $0 != 0 }
    }
}

/// Computes a 0...1 RMS level from an audio buffer for VU meters.
enum AudioMeter {
    static func level(from buffer: AVAudioPCMBuffer) -> Float {
        AudioConvert.withFloatChannel(from: buffer) { data, count, stride in
            var rms: Float = 0
            vDSP_rmsqv(data, vDSP_Stride(stride), &rms, vDSP_Length(count))
            let avgPower = 20 * log10(max(rms, 0.000_001))
            return min(1, max(0, (avgPower + 60) / 60))
        } ?? 0
    }
}
