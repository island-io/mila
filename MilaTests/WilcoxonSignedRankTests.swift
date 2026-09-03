import XCTest
@testable import Mila

/// Pins `WilcoxonSignedRank` — the paired significance test the seed-anchor
/// sweep (#206) uses to decide whether a difference in per-speaker recall is
/// worth acting on.
///
/// ## Why this needs its own tests
///
/// The sweep's *p*-values are the gate on changing
/// `LiveSpeakerDiarizer.seedAnchorWeight`, a constant that affects every user
/// with stored voice profiles. A subtly wrong test statistic would not look
/// wrong — it would produce plausible *p*-values and licence a change on
/// invented evidence, which is a worse outcome than having no test at all.
///
/// Every expected value below was cross-checked against exhaustive
/// enumeration of all 2ⁿ sign assignments, computed outside Swift. The
/// implementation reaches the same numbers by a dynamic program over doubled
/// ranks, so the two disagree if either is wrong.
final class WilcoxonSignedRankTests: XCTestCase {

    private func outcome(_ differences: [Double]) -> WilcoxonSignedRank.Outcome {
        // Expressed as (candidate, baseline) pairs against a zero baseline,
        // which is what the harness does with per-speaker recall.
        WilcoxonSignedRank.test(pairs: differences.map { (candidate: $0, baseline: 0.0) })
    }

    /// The textbook case: eight speakers, every one improved, no ties. The
    /// exact two-sided *p* has a closed form — only the all-positive and
    /// all-negative sign assignments are at least as extreme, so p = 2/2⁸.
    func test_all_eight_speakers_improving_gives_the_closed_form_p() {
        let result = outcome([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])
        XCTAssertEqual(result.sampleSize, 8)
        XCTAssertEqual(result.statistic, 36, accuracy: 1e-9, "W+ = 1+2+…+8")
        XCTAssertEqual(result.pValue, 2.0 / 256.0, accuracy: 1e-12)
        XCTAssertEqual(result.medianDifference, 0.45, accuracy: 1e-12)
    }

    /// Six speakers up, two barely down — the shape a real marginal result
    /// takes. p = 0.0390625 exactly (10/256).
    func test_a_marginal_result_gets_a_marginal_p() {
        let result = outcome([0.05, 0.10, 0.15, 0.20, 0.25, 0.30, -0.02, -0.03])
        XCTAssertEqual(result.sampleSize, 8)
        XCTAssertEqual(result.statistic, 33, accuracy: 1e-9)
        XCTAssertEqual(result.pValue, 10.0 / 256.0, accuracy: 1e-12)
        XCTAssertGreaterThan(result.medianDifference, 0)
    }

    /// Ties in |d| take average ranks, and a zero difference is dropped —
    /// so the sample size the *p* refers to is seven, not eight. Both matter
    /// when reading a sweep: a cell whose *p* rests on three non-zero
    /// speakers is not evidence, and only `sampleSize` says so.
    func test_ties_are_average_ranked_and_zero_differences_are_dropped() {
        let result = outcome([0.1, 0.1, -0.1, 0.2, 0.0, 0.4, 0.5, -0.6])
        XCTAssertEqual(result.sampleSize, 7, "the zero difference carries no sign")
        XCTAssertEqual(result.statistic, 19, accuracy: 1e-9,
                       "three |d| = 0.1 share ranks 1, 2, 3 as 2 each; two of them positive")
        XCTAssertEqual(result.pValue, 31.0 / 64.0, accuracy: 1e-12)
    }

    /// Nothing to test is not the same as no effect, but it must not report a
    /// significant one either.
    func test_no_differences_at_all_reports_no_evidence() {
        let result = outcome([0, 0, 0])
        XCTAssertEqual(result.sampleSize, 0)
        XCTAssertEqual(result.pValue, 1.0)
        XCTAssertEqual(result.medianDifference, 0)
    }

    /// A single speaker cannot produce a two-sided *p* below 1, and one that
    /// cancels exactly cannot either. Both are guards against a sweep run on
    /// a corpus far below #206's bar of eight speakers reporting significance.
    func test_a_tiny_sample_cannot_be_significant() {
        XCTAssertEqual(outcome([0.4]).pValue, 1.0, accuracy: 1e-12)
        XCTAssertEqual(outcome([0.4, -0.4]).pValue, 1.0, accuracy: 1e-12)
    }

    /// Direction is carried by the statistic and the median, not by the *p*:
    /// the test is two-sided, so a uniformly *worse* candidate is exactly as
    /// significant as a uniformly better one, and only `medianDifference`
    /// says which way.
    func test_the_p_is_two_sided_and_the_direction_is_in_the_median() {
        let better = outcome([0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8])
        let worse = outcome([-0.1, -0.2, -0.3, -0.4, -0.5, -0.6, -0.7, -0.8])
        XCTAssertEqual(better.pValue, worse.pValue, accuracy: 1e-12)
        XCTAssertEqual(worse.statistic, 0, accuracy: 1e-9)
        XCTAssertLessThan(worse.medianDifference, 0)
        XCTAssertGreaterThan(better.medianDifference, 0)
    }

    /// `compare` pairs on speaker identity, and drops a speaker who is missing
    /// from either side rather than scoring them zero. Inventing a zero would
    /// invent evidence — a speaker absent from one configuration was not
    /// measured there, which is not the same as having been recognised none of
    /// the time.
    func test_comparing_per_speaker_recall_pairs_by_name() {
        let candidate = ["alice": 0.9, "bob": 0.8, "carol": 0.5]
        let baseline = ["bob": 0.4, "alice": 0.5, "dave": 0.9]
        let result = WilcoxonSignedRank.compare(candidate: candidate, baseline: baseline)
        XCTAssertEqual(result.sampleSize, 2, "only alice and bob appear on both sides")
        XCTAssertEqual(result.medianDifference, 0.4, accuracy: 1e-9,
                       "alice +0.4 and bob +0.4")
    }
}
