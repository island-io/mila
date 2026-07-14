import XCTest
@testable import TranscriptionCore

final class HallucinationFilterTests: XCTestCase {

    func test_removes_exact_torzok_credit() {
        let input = "Субтитры создавал DimaTorzok"
        let output = WhisperEngine.cleanWhisperText(input)
        XCTAssertEqual(output, "")
    }

    func test_removes_lowercase_torzok_credit() {
        let input = "субтитры создавал dimatorzok"
        let output = WhisperEngine.cleanWhisperText(input)
        XCTAssertEqual(output, "")
    }

    func test_removes_torzok_only() {
        let input = "DimaTorzok"
        let output = WhisperEngine.cleanWhisperText(input)
        XCTAssertEqual(output, "")
    }

    func test_removes_english_credits() {
        let input = "Subtitles by"
        let output = WhisperEngine.cleanWhisperText(input)
        XCTAssertEqual(output, "")
    }

    func test_removes_credits_from_longer_sentence_if_mostly_credits() {
        let input = "Субтитры создавал DimaTorzok."
        let output = WhisperEngine.cleanWhisperText(input)
        XCTAssertEqual(output, "")
    }

    func test_keeps_legitimate_speech() {
        let input = "Сегодня мы будем обсуждать новые технологии в разработке."
        let output = WhisperEngine.cleanWhisperText(input)
        XCTAssertEqual(output, input)
    }
}
