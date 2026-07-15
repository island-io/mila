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

    // MARK: - Tail-strip behavior (preceding speech is preserved)

    func test_keeps_preceding_speech_when_credit_trails_segment() {
        // The credit hallucination is appended to a real sentence. We must
        // keep "Мы обсуждали технологии." and only drop the credit tail —
        // previously the whole segment was blanked, losing real speech.
        let input = "Мы обсуждали технологии. Субтитры создавал DimaTorzok"
        let output = WhisperEngine.cleanWhisperText(input)
        XCTAssertEqual(output, "Мы обсуждали технологии.")
    }

    func test_removes_subtitles_by_amara_credit() {
        // The exact-match ("subtitles by" == ...) would have let this through.
        // Substring + tail-strip catches "Subtitles by" followed by a name.
        let input = "Subtitles by Amara.org"
        let output = WhisperEngine.cleanWhisperText(input)
        XCTAssertEqual(output, "")
    }

    func test_removes_plural_created_credit() {
        // "субтитры создали" (plural "they created") is a separate fragment.
        let input = "Субтитры создали DimaTorzok"
        let output = WhisperEngine.cleanWhisperText(input)
        XCTAssertEqual(output, "")
    }

    func test_strips_trailing_punctuation_only_remainder() {
        // After removing the credit only a stray "." remains; the segment
        // should collapse to "" rather than emitting punctuation.
        let input = "Субтитры создавал DimaTorzok."
        let output = WhisperEngine.cleanWhisperText(input)
        XCTAssertEqual(output, "")
    }
}
