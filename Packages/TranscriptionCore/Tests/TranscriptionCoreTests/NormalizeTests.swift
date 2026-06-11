import XCTest
@testable import TranscriptionCore

final class NormalizeTests: XCTestCase {

    func test_empty_input_returns_empty() {
        let result = WhisperEngine.normalize([])
        XCTAssertTrue(result.isEmpty)
    }

    func test_silence_returns_silence() {
        let result = WhisperEngine.normalize([0, 0, 0])
        XCTAssertEqual(result, [0, 0, 0])
    }

    func test_loud_signal_is_not_boosted() {
        let input: [Float] = [0.5, -0.5, 0.3]
        let result = WhisperEngine.normalize(input)
        XCTAssertEqual(result, input)
    }

    func test_quiet_signal_is_boosted_toward_target() {
        let input: [Float] = [0.01, -0.01]
        let result = WhisperEngine.normalize(input)
        let peak = result.map { abs($0) }.max()!
        XCTAssertGreaterThan(peak, 0.1)
    }

    func test_gain_is_capped_at_20x() {
        let input: [Float] = [0.001]
        let result = WhisperEngine.normalize(input)
        XCTAssertEqual(result[0], 0.02, accuracy: 0.001)
    }

    func test_output_is_clamped_to_minus_one_one() {
        let input: [Float] = [0.1, -0.08]
        let result = WhisperEngine.normalize(input)
        for s in result {
            XCTAssertGreaterThanOrEqual(s, -1.0)
            XCTAssertLessThanOrEqual(s, 1.0)
        }
    }
}
