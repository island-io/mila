import XCTest
@testable import TranscriptionCore

/// Tests for `WhisperEngine.languageParams(for:)` — the policy behind the
/// `params.language` / `params.detect_language` pair passed to `whisper_full`.
///
/// Regression: the engine used to set `detect_language = true` whenever the
/// language was "auto" (or empty). In whisper.cpp, `detect_language` does NOT
/// mean "auto-detect then transcribe" — it means "return right after language
/// detection, skip transcription" (`if (params.detect_language) return 0;`
/// in whisper_full). Passing `language = "auto"` alone already triggers
/// detect-and-transcribe. The result: every local transcription with the 🌐
/// Auto-detect toolbar language completed "successfully" with ZERO segments —
/// an empty transcript, no error anywhere. (The remote path was unaffected,
/// which masked the bug for remote-backend users.)
final class LanguageParamsTests: XCTestCase {

    func test_auto_language_never_sets_detect_language() {
        let p = WhisperEngine.languageParams(for: "auto")
        XCTAssertEqual(p.language, "auto")
        XCTAssertFalse(p.detectLanguage,
                       "detect_language=true makes whisper_full return before transcribing — Auto-detect must rely on language=\"auto\" alone")
    }

    func test_empty_language_normalizes_to_auto_without_detect_flag() {
        let p = WhisperEngine.languageParams(for: "")
        XCTAssertEqual(p.language, "auto",
                       "whisper_lang_id rejects an empty string; it must normalize to \"auto\"")
        XCTAssertFalse(p.detectLanguage)
    }

    func test_explicit_languages_pass_through_unchanged() {
        for lang in ["en", "he"] {
            let p = WhisperEngine.languageParams(for: lang)
            XCTAssertEqual(p.language, lang)
            XCTAssertFalse(p.detectLanguage)
        }
    }
}
