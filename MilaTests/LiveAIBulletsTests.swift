import XCTest
@testable import Mila

/// Tests for `LiveAIRecordingView.bulletsFromSummary` — the live Summary
/// pane's sentence splitter.
///
/// Regression: the original implementation split on every '.', '!', '?'
/// CHARACTER, so a summary containing a decimal ("the budget is 3.5
/// million") shattered into nonsense bullets mid-number — while the detail
/// pane (`AIOverviewSection.summaryAttributed`) already used Foundation's
/// `.bySentences` tokenizer and rendered the same summary correctly. The two
/// panes now share the same splitting behavior.
@MainActor
final class LiveAIBulletsTests: XCTestCase {

    func test_decimal_numbers_stay_within_one_bullet() {
        let bullets = LiveAIRecordingView.bulletsFromSummary(
            "The budget is 3.5 million. Next review is scheduled.")
        XCTAssertEqual(bullets.count, 2, "Two sentences → two bullets, got \(bullets)")
        XCTAssertTrue(bullets[0].contains("3.5 million"),
                      "The decimal must not be split mid-number: \(bullets)")
    }

    func test_plain_sentences_split_one_bullet_each() {
        let bullets = LiveAIRecordingView.bulletsFromSummary(
            "First point here. Second point there. Third one closes.")
        XCTAssertEqual(bullets.count, 3, "got \(bullets)")
    }

    func test_newline_structured_summary_splits_per_line() {
        let bullets = LiveAIRecordingView.bulletsFromSummary(
            "- migration plan agreed\n- rollout starts Monday")
        XCTAssertEqual(bullets.count, 2, "got \(bullets)")
    }

    func test_empty_and_whitespace_summaries_yield_no_bullets() {
        XCTAssertEqual(LiveAIRecordingView.bulletsFromSummary(""), [])
        XCTAssertEqual(LiveAIRecordingView.bulletsFromSummary("  \n "), [])
    }

    func test_no_boundary_falls_back_to_single_bullet() {
        let bullets = LiveAIRecordingView.bulletsFromSummary("just one clause with no period")
        XCTAssertEqual(bullets, ["just one clause with no period"])
    }
}
