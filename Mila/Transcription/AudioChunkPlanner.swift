import Accelerate
import Foundation
import TranscriptionCore

/// Where to cut a long recording so that each piece fits in one remote
/// transcription request (#376).
///
/// A remote server caps what one request may carry. OpenAI's
/// `gpt-4o(-mini)-transcribe` refuses anything much past 25 minutes outright
/// (`input_too_large`), and stops writing after 2,000 output tokens — about
/// eight minutes of English speech, less of Hebrew — so a long upload either
/// fails or comes back silently cut short. Sending a 74-minute Voice Memo in
/// one request did the former every time. The live path never hit this: it
/// sends one utterance at a time.
///
/// The pieces are contiguous and cover every sample exactly once, so a
/// segment's time inside a piece plus the piece's start is its time in the
/// recording — speaker alignment, SRT export and playback seek need nothing
/// else. Each cut goes in the quietest stretch near the end of the allowed
/// length (a pause between sentences, in practice), not mid-word.
///
/// Pure and deterministic, so the boundaries can be tested without audio
/// files or a server.
enum AudioChunkPlanner {
    /// Energy is measured in frames this long.
    static let frameSeconds: Double = 0.02
    /// A cut goes in the middle of the quietest stretch this long — long
    /// enough to be a pause rather than the gap inside a word.
    static let pauseSeconds: Double = 0.4
    /// How far back from the length limit a cut may move to find that pause.
    /// Capped at a quarter of the limit, so a piece is never shorter than
    /// three quarters of it.
    static let searchWindowSeconds: Double = 30
    /// The last piece is never shorter than this. A server refuses a clip
    /// that is too short (OpenAI: under 0.1 s), and a sliver of audio would
    /// fail the whole recording for nothing.
    static let minimumTailSeconds: Double = 1

    /// Split `samples` into ranges of at most `maxChunkSeconds` each.
    ///
    /// Returns no ranges for empty input, and one range for input that
    /// already fits or a limit that is not a positive number. Otherwise every
    /// range is non-empty, no longer than the
    /// limit, starts where the previous one ended, and together they cover
    /// `0..<samples.count`.
    static func plan(samples: [Float],
                     sampleRate: Double = WhisperAudioFormat.sampleRate,
                     maxChunkSeconds: Double) -> [Range<Int>] {
        let count = samples.count
        guard count > 0 else { return [] }
        // A limit that is not a positive number means "no limit" — and must
        // never reach `Int(_:)`, which traps on a non-finite value.
        let limitSamples = (maxChunkSeconds * sampleRate).rounded(.down)
        guard limitSamples.isFinite, limitSamples >= 1, Double(count) > limitSamples else {
            return [0..<count]
        }
        let maxLength = Int(limitSamples)

        let window = max(1, min(Int(searchWindowSeconds * sampleRate), maxLength / 4))
        // At most half the search window, so the window always has room for
        // a cut that leaves the tail at least this long.
        let minimumTail = min(Int(minimumTailSeconds * sampleRate), window / 2)

        var ranges: [Range<Int>] = []
        var start = 0
        while count - start > maxLength {
            let hardEnd = start + maxLength
            let earliest = hardEnd - window
            let latest = min(hardEnd, count - minimumTail)
            let cut = quietestCut(in: samples, from: earliest, to: latest, sampleRate: sampleRate)
            // `earliest > start` whenever `maxLength > 1`; the clamp makes
            // progress unconditional.
            let end = min(hardEnd, max(start + 1, cut))
            ranges.append(start..<end)
            start = end
        }
        ranges.append(start..<count)
        return ranges
    }

    /// The sample index in `lower...upper` at the middle of the quietest
    /// `pauseSeconds` of audio there. Ties go to the later position, so a
    /// run of silence yields the longest piece the limit allows.
    static func quietestCut(in samples: [Float], from lower: Int, to upper: Int,
                            sampleRate: Double) -> Int {
        let frame = max(1, Int(frameSeconds * sampleRate))
        let frameCount = (upper - lower) / frame
        guard frameCount > 0 else { return upper }

        var energy = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for k in 0..<frameCount {
                var sumOfSquares: Float = 0
                vDSP_svesq(base + lower + k * frame, 1, &sumOfSquares, vDSP_Length(frame))
                energy[k] = sumOfSquares
            }
        }

        // Each window is summed afresh rather than as a running total: a
        // running total drifts in floating point, and a run of exact silence
        // must compare equal to itself for the tie rule to hold.
        let pauseFrames = min(frameCount, max(1, Int((pauseSeconds / frameSeconds).rounded())))
        var best = Float.infinity
        var bestStart = 0
        for k in 0...(frameCount - pauseFrames) {
            let windowEnergy = energy[k..<(k + pauseFrames)].reduce(0, +)
            if windowEnergy <= best {
                best = windowEnergy
                bestStart = k
            }
        }
        let cut = lower + (bestStart * frame) + (pauseFrames * frame) / 2
        return min(upper, max(lower, cut))
    }
}
