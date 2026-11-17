import XCTest
@testable import Mila

/// `LiveAISettings.OutputLanguage` is "auto" or any language whisper knows,
/// not just auto/en/he, so a Russian meeting can get a Russian summary.
final class OutputLanguageTests: XCTestCase {

    // MARK: - Stored values

    /// The raw values were already "auto"/"en"/"he", so existing settings
    /// read back unchanged and nothing needs migrating.
    func test_existing_stored_values_read_back_unchanged() {
        XCTAssertEqual(LiveAISettings.OutputLanguage(stored: "auto"), .auto)
        XCTAssertEqual(LiveAISettings.OutputLanguage(stored: "en"), .english)
        XCTAssertEqual(LiveAISettings.OutputLanguage(stored: "he"), .hebrew)
    }

    func test_any_supported_language_can_be_stored() {
        XCTAssertEqual(LiveAISettings.OutputLanguage(stored: "ru").rawValue, "ru")
        XCTAssertEqual(LiveAISettings.OutputLanguage(stored: "RU").rawValue, "ru")
    }

    /// The defaults plist is user-editable: junk falls back to Auto, never
    /// to a guessed language.
    func test_junk_reads_as_auto() {
        XCTAssertEqual(LiveAISettings.OutputLanguage(stored: nil), .auto)
        XCTAssertEqual(LiveAISettings.OutputLanguage(stored: "klingon"), .auto)
        XCTAssertEqual(LiveAISettings.OutputLanguage(stored: ""), .auto)
    }

    func test_display_name() {
        XCTAssertEqual(LiveAISettings.OutputLanguage.auto.displayName, "Auto")
        XCTAssertEqual(LiveAISettings.OutputLanguage.hebrew.displayName, "Hebrew")
        XCTAssertEqual(LiveAISettings.OutputLanguage(stored: "ru").displayName, "Russian")
    }

    // MARK: - The language name a prompt asks for

    private func name(_ output: LiveAISettings.OutputLanguage, code: String, text: String) -> String {
        LiveAISettings.OutputLanguage.promptName(output: output, recordingCode: code, text: text)
    }

    /// An explicit choice applies whatever the recording's language.
    func test_an_explicit_language_is_used_as_is() {
        XCTAssertEqual(name(.english, code: "he", text: "שלום"), "English")
        XCTAssertEqual(name(LiveAISettings.OutputLanguage(stored: "ru"), code: "en", text: "hi"), "Russian")
    }

    /// Auto on a language the user added: the recording's own language.
    /// Before this, the first Russian recording got an English summary.
    func test_auto_follows_an_added_language() {
        XCTAssertEqual(name(.auto, code: "ru", text: "Всем привет"), "Russian")
        XCTAssertEqual(name(.auto, code: "ar", text: "مرحبا"), "Arabic")
    }

    /// For Hebrew and English, Auto keeps reading the text, as it did
    /// before: a Hebrew recording where people spoke English gets English.
    func test_auto_reads_the_text_for_hebrew_and_english() {
        XCTAssertEqual(name(.auto, code: "he", text: "we discussed the roadmap"), "English")
        XCTAssertEqual(name(.auto, code: "en", text: "דיברנו על מפת הדרכים"), "Hebrew")
        XCTAssertEqual(name(.auto, code: "he", text: "דיברנו על מפת הדרכים"), "Hebrew")
    }

    /// Codes that say nothing about what was spoken fall back to the text.
    func test_auto_reads_the_text_for_legacy_and_unknown_codes() {
        XCTAssertEqual(name(.auto, code: "auto", text: "we discussed the roadmap"), "English")
        XCTAssertEqual(name(.auto, code: "", text: "דיברנו"), "Hebrew")
        XCTAssertEqual(name(.auto, code: "klingon", text: "we discussed"), "English")
    }

    /// A regional form means its base language.
    func test_auto_reads_a_regional_code_as_its_base_language() {
        XCTAssertEqual(name(.auto, code: "ru-RU", text: "Всем привет"), "Russian")
    }

    // MARK: - Per-recording summary language

    func test_summary_override_accepts_any_supported_language() {
        XCTAssertEqual(RecordingLanguage.summaryLanguage(stored: "ru")?.code, "ru")
        XCTAssertEqual(RecordingLanguage.summaryLanguage(stored: "he")?.code, "he")
        XCTAssertEqual(RecordingLanguage.summaryLanguage(stored: "he")?.flagEmoji, "🇮🇱")
    }

    /// recordings.json and .milashare files are untrusted: anything the app
    /// never writes is "no override", never a guess.
    func test_summary_override_rejects_codes_the_app_never_writes() {
        XCTAssertNil(RecordingLanguage.summaryLanguage(stored: "klingon"))
        XCTAssertNil(RecordingLanguage.summaryLanguage(stored: "he-IL"))
        XCTAssertNil(RecordingLanguage.summaryLanguage(stored: "HE"))
        XCTAssertNil(RecordingLanguage.summaryLanguage(stored: "auto"))
        XCTAssertNil(RecordingLanguage.summaryLanguage(stored: ""))
    }
}
