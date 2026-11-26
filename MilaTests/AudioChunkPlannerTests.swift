import XCTest
@testable import Mila

/// Issue #376: a remote whole-recording transcription is split into pieces
/// the server accepts. These pin where `AudioChunkPlanner` cuts: never past
/// the limit, at a pause when there is one, contiguous and covering every
/// sample once (so a piece's start plus a time inside it is a time in the
/// recording), and never leaving a sliver at the end.
final class AudioChunkPlannerTests: XCTestCase {

    private let rate: Double = 16_000

    private func tone(_ seconds: Double, rate: Double = 16_000) -> [Float] {
        (0..<Int(seconds * rate)).map { i in 0.3 * Float(sin(2 * Double.pi * 220 * Double(i) / rate)) }
    }

    private func silence(_ seconds: Double, rate: Double = 16_000) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    /// Every invariant the stitching relies on, for any plan.
    private func assertWellFormed(_ ranges: [Range<Int>], count: Int, limitSeconds: Double,
                                  rate: Double = 16_000,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(ranges.isEmpty, file: file, line: line)
        XCTAssertEqual(ranges.first?.lowerBound, 0, "starts at the first sample", file: file, line: line)
        XCTAssertEqual(ranges.last?.upperBound, count, "ends at the last sample", file: file, line: line)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(a.upperBound, b.lowerBound, "pieces are contiguous", file: file, line: line)
        }
        for range in ranges {
            XCTAssertFalse(range.isEmpty, file: file, line: line)
            XCTAssertLessThanOrEqual(Double(range.count), limitSeconds * rate,
                                     "no piece is longer than the limit", file: file, line: line)
        }
    }

    func test_empty_input_has_no_pieces() {
        XCTAssertEqual(AudioChunkPlanner.plan(samples: [], maxChunkSeconds: 10), [])
    }

    func test_audio_that_fits_is_one_piece() {
        let samples = tone(9.5)
        XCTAssertEqual(AudioChunkPlanner.plan(samples: samples, maxChunkSeconds: 10),
                       [0..<samples.count])
        let exact = tone(10)
        XCTAssertEqual(AudioChunkPlanner.plan(samples: exact, maxChunkSeconds: 10),
                       [0..<exact.count], "exactly the limit still fits")
    }

    func test_a_limit_that_is_not_a_positive_number_means_one_piece() {
        let samples = tone(3)
        for limit in [0, -5, Double.nan, Double.infinity] {
            XCTAssertEqual(AudioChunkPlanner.plan(samples: samples, maxChunkSeconds: limit),
                           [0..<samples.count], "limit \(limit)")
        }
    }

    /// The point of cutting at a pause: the boundary falls in the gap
    /// between words, not in the middle of one.
    func test_cuts_fall_in_the_pause_nearest_the_limit() {
        // Speech with two half-second pauses, each inside the last quarter
        // of where its piece would hit the 10 s limit (the search window is
        // capped at a quarter of the limit: 2.5 s here).
        let samples = tone(8.0) + silence(0.5) + tone(8.5) + silence(0.5) + tone(7.5)
        let ranges = AudioChunkPlanner.plan(samples: samples, maxChunkSeconds: 10)
        assertWellFormed(ranges, count: samples.count, limitSeconds: 10)
        XCTAssertEqual(ranges.count, 3)
        let firstCut = Double(ranges[0].upperBound) / rate
        let secondCut = Double(ranges[1].upperBound) / rate
        XCTAssertGreaterThanOrEqual(firstCut, 8.0)
        XCTAssertLessThanOrEqual(firstCut, 8.5)
        XCTAssertGreaterThanOrEqual(secondCut, 17.0)
        XCTAssertLessThanOrEqual(secondCut, 17.5)
    }

    /// A pause farther back than the search window is not worth a piece
    /// that short: the cut stays in the window, so every piece but the last
    /// is at least three quarters of the limit.
    func test_a_pause_outside_the_search_window_is_not_used() {
        let samples = tone(2) + silence(1) + tone(20)
        let ranges = AudioChunkPlanner.plan(samples: samples, maxChunkSeconds: 10)
        assertWellFormed(ranges, count: samples.count, limitSeconds: 10)
        for range in ranges.dropLast() {
            XCTAssertGreaterThanOrEqual(Double(range.count) / rate, 7.5)
        }
    }

    /// Someone who never pauses still gets pieces under the limit.
    func test_audio_with_no_pause_is_still_cut_within_the_limit() {
        let samples = tone(35)
        let ranges = AudioChunkPlanner.plan(samples: samples, maxChunkSeconds: 10)
        assertWellFormed(ranges, count: samples.count, limitSeconds: 10)
        // Each cut is somewhere in the last 2.5 s before its limit: 4 pieces
        // if they all fall late, 5 if they all fall early.
        XCTAssertTrue((4...5).contains(ranges.count), "\(ranges.count) pieces")
    }

    /// A long run of silence: ties go to the later position, so the piece is
    /// as long as the limit allows rather than cut at the first quiet frame.
    func test_silence_yields_the_longest_piece_the_limit_allows() {
        let samples = tone(5) + silence(20)
        let ranges = AudioChunkPlanner.plan(samples: samples, maxChunkSeconds: 10)
        assertWellFormed(ranges, count: samples.count, limitSeconds: 10)
        XCTAssertGreaterThanOrEqual(Double(ranges[0].count) / rate, 9.5)
    }

    /// Audio barely over the limit must not end in a sliver the server
    /// would refuse (OpenAI: anything under 0.1 s).
    func test_the_last_piece_is_never_a_sliver() {
        let samples = tone(10) + [0.3, -0.3, 0.3]
        let ranges = AudioChunkPlanner.plan(samples: samples, maxChunkSeconds: 10)
        assertWellFormed(ranges, count: samples.count, limitSeconds: 10)
        XCTAssertEqual(ranges.count, 2)
        // min(1 s, half the 2.5 s search window)
        XCTAssertGreaterThanOrEqual(Double(ranges[1].count) / rate, 1.0)
    }

    /// The shape of the bug report: a 74-minute memo, 4-minute pieces. Run at
    /// a low sample rate so the test holds kilobytes, not 280 MB of audio.
    func test_a_74_minute_memo_becomes_pieces_of_three_to_four_minutes() {
        let lowRate: Double = 100
        let samples = (0..<Int(74 * 60 * lowRate)).map { i -> Float in
            // A pause of 0.5 s every 7 s, like sentences.
            Int(Double(i) / lowRate * 2) % 14 == 13 ? 0 : 0.3
        }
        let ranges = AudioChunkPlanner.plan(samples: samples, sampleRate: lowRate, maxChunkSeconds: 240)
        assertWellFormed(ranges, count: samples.count, limitSeconds: 240, rate: lowRate)
        XCTAssertGreaterThanOrEqual(ranges.count, 19)
        XCTAssertLessThanOrEqual(ranges.count, 25)
        for range in ranges.dropLast() {
            XCTAssertGreaterThanOrEqual(Double(range.count) / lowRate, 180)
        }
    }

    func test_quietest_cut_is_the_middle_of_the_quietest_stretch() {
        let samples = tone(1) + silence(0.4) + tone(1)
        let cut = AudioChunkPlanner.quietestCut(in: samples, from: 0, to: samples.count, sampleRate: rate)
        XCTAssertEqual(Double(cut) / rate, 1.2, accuracy: 0.03)
    }
}
