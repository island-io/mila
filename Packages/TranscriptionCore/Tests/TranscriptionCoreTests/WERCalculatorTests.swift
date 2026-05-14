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
}
