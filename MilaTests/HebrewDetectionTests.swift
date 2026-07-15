import XCTest
@testable import Mila

/// Characterization tests for the script-detection predicates. The two
/// predicates must be **mutually exclusive** and share one counting model:
/// Russian-dominant text with a sprinkling of Hebrew must not be classified
/// as Hebrew (Russian is LTR), and mixed Hebrew/Russian must resolve to
/// exactly one verdict regardless of which predicate the caller checks first.
final class HebrewDetectionTests: XCTestCase {

    // MARK: - isPredominantlyHebrew

    func test_pure_hebrew_is_predominantly_hebrew() {
        XCTAssertTrue("שלום עולם מה שלומך".isPredominantlyHebrew)
    }

    func test_pure_english_is_not_predominantly_hebrew() {
        XCTAssertFalse("Hello world how are you".isPredominantlyHebrew)
    }

    func test_pure_russian_is_not_predominantly_hebrew() {
        // Russian is LTR; this is the regression the unified counters protect
        // against — previously Hebrew-only-vs-Latin ignored Cyrillic, so a
        // few Hebrew words in Russian text flipped it to RTL.
        XCTAssertFalse("Сегодня мы будем обсуждать новые технологии".isPredominantlyHebrew)
    }

    func test_russian_with_a_few_hebrew_words_is_not_predominantly_hebrew() {
        // 88% Cyrillic, ~9% Hebrew, ~3% Latin. Must NOT be Hebrew.
        XCTAssertFalse("Сегодня обсудим проект и слово שלום в контексте Cursor".isPredominantlyHebrew)
    }

    func test_empty_string_is_not_predominantly_hebrew() {
        XCTAssertFalse("".isPredominantlyHebrew)
    }

    // MARK: - isPredominantlyCyrillic

    func test_pure_russian_is_predominantly_cyrillic() {
        XCTAssertTrue("Сегодня мы будем обсуждать новые технологии".isPredominantlyCyrillic)
    }

    func test_pure_english_is_not_predominantly_cyrillic() {
        XCTAssertFalse("Hello world how are you".isPredominantlyCyrillic)
    }

    func test_pure_hebrew_is_not_predominantly_cyrillic() {
        XCTAssertFalse("שלום עולם מה שלומך".isPredominantlyCyrillic)
    }

    func test_empty_string_is_not_predominantly_cyrillic() {
        XCTAssertFalse("".isPredominantlyCyrillic)
    }

    // MARK: - Mutual exclusivity

    func test_minority_cyrillic_is_not_predominantly_cyrillic() {
        // Cyrillic is present but does not dominate. The old >= 0.3 threshold
        // would have returned true here, misrouting the summarizer to Russian.
        XCTAssertFalse("Hello world this is mostly English текст here".isPredominantlyCyrillic)
    }

    func test_predicates_are_mutually_exclusive_for_mixed_hebrew_russian() {
        // Hebrew-dominant with a meaningful Russian passage: must be Hebrew,
        // not Russian, regardless of call order. (Previously the Cyrillic
        // >= 0.3 threshold would also flag this as Cyrillic, so the verdict
        // depended on which predicate the caller checked first.)
        let mixed = "אני מדבר עברית וזה טקסט ארוך בעברית עם המון מילים לבדיקה привет мир"
        XCTAssertTrue(mixed.isPredominantlyHebrew)
        XCTAssertFalse(mixed.isPredominantlyCyrillic)
    }
}