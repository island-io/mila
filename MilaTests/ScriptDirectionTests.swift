import XCTest
@testable import Mila

/// Script direction is decided from the language and from the text itself.
/// Before user-editable languages both were Hebrew-only: `== "he"` and a
/// Hebrew-vs-Latin letter count. An Arabic transcript, or a Russian summary
/// of a Hebrew recording, got the wrong side.
final class ScriptDirectionTests: XCTestCase {

    // MARK: - From the language code

    func test_rtl_follows_the_language_code() {
        for code in ["he", "ar", "fa", "ur", "yi"] {
            XCTAssertTrue(RecordingLanguage.isRTL(code: code), code)
        }
        for code in ["en", "ru", "de", "zh", "ja"] {
            XCTAssertFalse(RecordingLanguage.isRTL(code: code), code)
        }
    }

    /// Stored codes include legacy aliases and regional forms.
    func test_rtl_reads_aliases_and_regional_variants() {
        XCTAssertTrue(RecordingLanguage.isRTL(code: "iw"))
        XCTAssertTrue(RecordingLanguage.isRTL(code: "he-IL"))
        XCTAssertFalse(RecordingLanguage.isRTL(code: "auto"),
                       "legacy auto says nothing about the script — the text decides")
        XCTAssertFalse(RecordingLanguage.isRTL(code: ""), "same for a recording with no language")
        XCTAssertFalse(RecordingLanguage.isRTL(code: "en_GB"))
    }

    // MARK: - From the text

    func test_text_direction_counts_every_rtl_script() {
        XCTAssertTrue("שלום לכולם".isPredominantlyRTL)
        XCTAssertTrue("مرحبا بالجميع".isPredominantlyRTL)
        XCTAssertTrue("سلام به همه".isPredominantlyRTL)
        XCTAssertFalse("Hello everyone".isPredominantlyRTL)
        XCTAssertFalse("Всем привет".isPredominantlyRTL)
    }

    /// A Latin brand name inside a Hebrew sentence must not flip it.
    func test_text_direction_is_a_majority_vote() {
        XCTAssertTrue("אמרתי לו שנשתמש ב Cursor מחר".isPredominantlyRTL)
        XCTAssertFalse("We met at מילה today and talked".isPredominantlyRTL)
    }

    /// Cyrillic counts as left-to-right letters: a Russian summary must give
    /// a verdict of its own instead of falling back to a Hebrew recording's
    /// language.
    func test_any_script_counts_as_letters() {
        XCTAssertTrue("Всем привет".hasDirectionalLetters)
        XCTAssertTrue("مرحبا".hasDirectionalLetters)
        XCTAssertFalse("12:30 — …".hasDirectionalLetters)
        XCTAssertFalse("".hasDirectionalLetters)
    }
}
