import XCTest
@testable import TranscriptionCore

final class WERCalculatorTests: XCTestCase {

    func test_identical_strings_have_zero_wer() {
        let wer = WERCalculator.calculate(reference: "hello world", hypothesis: "hello world")
        XCTAssertEqual(wer, 0.0, accuracy: 0.001)
    }

    func test_completely_wrong_has_wer_of_one() {
        let wer = WERCalculator.calculate(reference: "hello world", hypothesis: "foo bar")
        XCTAssertEqual(wer, 1.0, accuracy: 0.001)
    }

    func test_one_substitution_in_two_words() {
        let wer = WERCalculator.calculate(reference: "hello world", hypothesis: "hello earth")
        XCTAssertEqual(wer, 0.5, accuracy: 0.001)
    }

    func test_insertion_increases_wer() {
        let wer = WERCalculator.calculate(reference: "hello world", hypothesis: "hello big world")
        XCTAssertGreaterThan(wer, 0)
        XCTAssertLessThan(wer, 1.0)
    }

    func test_deletion_increases_wer() {
        let wer = WERCalculator.calculate(reference: "hello big world", hypothesis: "hello world")
        XCTAssertGreaterThan(wer, 0)
        XCTAssertLessThan(wer, 1.0)
    }

    func test_empty_reference_returns_one_if_hypothesis_nonempty() {
        let wer = WERCalculator.calculate(reference: "", hypothesis: "hello")
        XCTAssertEqual(wer, 1.0)
    }

    func test_both_empty_returns_zero() {
        let wer = WERCalculator.calculate(reference: "", hypothesis: "")
        XCTAssertEqual(wer, 0.0)
    }

    func test_case_insensitive_comparison() {
        let wer = WERCalculator.calculate(reference: "Hello World", hypothesis: "hello world")
        XCTAssertEqual(wer, 0.0, accuracy: 0.001)
    }

    func test_hebrew_text() {
        let wer = WERCalculator.calculate(reference: "שלום עולם", hypothesis: "שלום עולם")
        XCTAssertEqual(wer, 0.0, accuracy: 0.001)
    }

    // MARK: - Apostrophe folding

    /// Regression: the tokenizer exempted only ASCII U+0027 from the
    /// punctuation strip, so a smart-quote reference ("don’t" — what most
    /// editors auto-insert) tokenized to "dont" while the hypothesis's
    /// ASCII "don't" stayed "don't": every contraction counted as a
    /// substitution purely because of the apostrophe form.
    func test_typographic_apostrophe_matches_ascii_apostrophe() {
        let wer = WERCalculator.calculate(reference: "don\u{2019}t stop",
                                          hypothesis: "don't stop")
        XCTAssertEqual(wer, 0.0, accuracy: 0.001,
                       "U+2019 and U+0027 apostrophes must normalize identically")
    }

    /// Same defect class for Hebrew: geresh (U+05F3) vs ASCII apostrophe
    /// in loanwords like ג׳ון / ג'ון.
    func test_hebrew_geresh_matches_ascii_apostrophe() {
        let wer = WERCalculator.calculate(reference: "ג\u{05F3}ון הלך",
                                          hypothesis: "ג'ון הלך")
        XCTAssertEqual(wer, 0.0, accuracy: 0.001,
                       "Hebrew geresh and ASCII apostrophe must normalize identically")
    }
}
