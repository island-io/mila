import XCTest
@testable import Mila

@MainActor
final class RecordingLanguageSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "RecordingLanguageSettingsTests"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func test_fresh_install_defaults_to_english() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.current, .english)
    }

    func test_assignment_persists_across_instances() {
        let first = RecordingLanguageSettings(defaults: defaults)
        first.current = .english

        let reloaded = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(reloaded.current, .english)
    }

    /// We render flag emoji in the toolbar — make sure they're stable so a
    /// future "let's localize the picker" change doesn't silently strip them.
    func test_flag_emojis_are_stable() {
        XCTAssertEqual(RecordingLanguage.hebrew.flagEmoji, "🇮🇱")
        XCTAssertEqual(RecordingLanguage.english.flagEmoji, "🇬🇧")
        XCTAssertEqual(RecordingLanguage.russian.flagEmoji, "🇷🇺")
    }

    /// `Recording.language` is a free-form ISO code (legacy `"he"`,
    /// `"he-IL"`, even `"iw"` from very old recordings). The decoding helper
    /// must keep all of those mapping to Hebrew.
    func test_language_code_decoding_handles_legacy_iso_variants() {
        XCTAssertEqual(RecordingLanguage.fromCode("he"), .hebrew)
        XCTAssertEqual(RecordingLanguage.fromCode("HE"), .hebrew)
        XCTAssertEqual(RecordingLanguage.fromCode("he-IL"), .hebrew)
        XCTAssertEqual(RecordingLanguage.fromCode("iw"), .hebrew)
        XCTAssertEqual(RecordingLanguage.fromCode("en"), .english)
        XCTAssertEqual(RecordingLanguage.fromCode("en-US"), .english)
        XCTAssertEqual(RecordingLanguage.fromCode("ru"), .russian)
        XCTAssertEqual(RecordingLanguage.fromCode("ru-RU"), .russian)
    }

    /// Unknown / future language codes fall back to Hebrew rather than
    /// crashing — recordings created before this struct existed are tagged
    /// "he", and the UI should treat anything unrecognized the same way.
    func test_unknown_language_code_falls_back_to_hebrew() {
        XCTAssertEqual(RecordingLanguage.fromCode("fr"), .hebrew)
        XCTAssertEqual(RecordingLanguage.fromCode(""), .hebrew)
    }

    /// Russian was added to the enum this branch; lock in its raw value and
    /// display name so a future refactor can't silently rename the persisted
    /// key (which would orphan recordings tagged "ru").
    func test_russian_raw_value_and_display_name_are_stable() {
        XCTAssertEqual(RecordingLanguage.russian.rawValue, "ru")
        XCTAssertEqual(RecordingLanguage.russian.displayName, "Russian")
        XCTAssertEqual(RecordingLanguage(rawValue: "ru"), .russian)
    }
}
