import XCTest
@testable import Mila

/// Characterization benchmark for the per-tick MODEL-side work in the
/// Live AI feed loop — the other hypothesis for the "slows down after 15
/// min" report (besides LLM-spawn frequency and SwiftUI re-render).
///
/// Each feed-loop tick rebuilds the flat transcript string that gets sent
/// to the LLM via `LiveTranscriber.formattedTranscript`
/// (`segments.map { "[mm:ss] text" }.joined()`). That's O(n) in the
/// segment count, which grows for the whole recording — so it's worth
/// quantifying whether it's actually expensive at 15-minute scale.
///
/// This mirrors that exact transform over a synthetic transcript (the
/// real property reads `private(set)` state we can't inject). `measure`
/// records the time as a metric without a stored baseline, so it reports
/// the number in the test log but cannot fail the build on a slow runner.
///
/// Expectation (and the point of measuring): for several hundred to ~1000
/// short segments this is sub-millisecond — i.e. NOT the bottleneck. The
/// correctness assertions below run normally and DO gate the build.
final class LiveAIFeedCostTests: XCTestCase {

    private func makeSegments(_ count: Int) -> [LiveSegment] {
        (0..<count).map { i in
            LiveSegment(
                id: UUID(),
                startSeconds: Double(i) * 4,          // a segment every ~4 s
                endSeconds: Double(i) * 4 + 3,
                text: "This is segment number \(i) with a sentence of realistic length.",
                speaker: i % 2 == 0 ? "SPEAKER_00" : "SPEAKER_01",
                stable: true)
        }
    }

    /// Exactly mirrors `LiveTranscriber.formattedTranscript`.
    private func formatted(_ segments: [LiveSegment]) -> String {
        segments.map { seg in
            let mm = Int(seg.startSeconds) / 60
            let ss = Int(seg.startSeconds) % 60
            return String(format: "[%02d:%02d] %@", mm, ss, seg.text)
        }.joined(separator: "\n")
    }

    func test_formattedTranscript_isCorrect_forSmallInput() {
        let segs = [
            LiveSegment(id: UUID(), startSeconds: 5, endSeconds: 7,
                        text: "hello", speaker: nil, stable: true),
            LiveSegment(id: UUID(), startSeconds: 65, endSeconds: 67,
                        text: "world", speaker: nil, stable: true),
        ]
        XCTAssertEqual(formatted(segs), "[00:05] hello\n[01:05] world")
    }

    /// ~1000 segments ≈ a long (well past 15-minute) VAD meeting. Records
    /// the per-tick formatting cost; see file header for interpretation.
    func test_formattedTranscript_cost_atLongMeetingScale() {
        let segs = makeSegments(1000)
        measure {
            for _ in 0..<10 { _ = formatted(segs) }   // 10 ticks' worth
        }
        // Sanity: the output is the expected size, so the work wasn't
        // optimized away by the compiler.
        XCTAssertEqual(formatted(segs).split(separator: "\n").count, 1000)
    }
}
