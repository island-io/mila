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

    func test_fresh_install_defaults_to_hebrew() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.current, .hebrew)
    }

    func test_assignment_persists_across_instances() {
        let first = RecordingLanguageSettings(defaults: defaults)
        first.current = .english

        let reloaded = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(reloaded.current, .english)
    }

    /// We render flag emoji in the toolbar — make sure the seeds carry them so
    /// a future "let's localize the picker" change doesn't silently strip them.
    func test_flag_emojis_are_stable() {
        XCTAssertEqual(RecordingLanguage.hebrew.flagEmoji, "🇮🇱")
        XCTAssertEqual(RecordingLanguage.english.flagEmoji, "🇬🇧")
    }

    /// `Recording.language` is a free-form ISO code (legacy `"he"`,
    /// `"he-IL"`, even `"iw"` from very old recordings). Resolution must keep
    /// all of those mapping to their base language.
    func test_language_code_resolution_handles_legacy_iso_variants() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.resolve("he").code, "he")
        XCTAssertEqual(settings.resolve("HE").code, "he")
        XCTAssertEqual(settings.resolve("he-IL").code, "he")
        XCTAssertEqual(settings.resolve("he_IL").code, "he")
        XCTAssertEqual(settings.resolve("iw").code, "he")
        XCTAssertEqual(settings.resolve("en").code, "en")
        XCTAssertEqual(settings.resolve("en-US").code, "en")
    }

    /// Replaces "unknown codes fall back to Hebrew". That fallback existed for
    /// recordings that pre-date the per-language UX, which carry `"auto"` or
    /// nothing — those still read as Hebrew. Any OTHER code now means what it
    /// says: a `"fr"` row displays as French, not as Hebrew.
    func test_legacy_codes_read_as_hebrew_but_unknown_codes_are_synthesized() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.resolve("").code, "he")
        XCTAssertEqual(settings.resolve("auto").code, "he")

        let french = settings.resolve("fr")
        XCTAssertEqual(french.code, "fr")
        XCTAssertEqual(french.displayName, "French")
        XCTAssertEqual(french.flagEmoji, "")
        XCTAssertNil(french.modelName, "unknown languages use the multilingual default")
        XCTAssertFalse(settings.languages.contains { $0.code == "fr" },
                       "resolving must not add to the user's list")
        XCTAssertNil(settings.configured("fr"), "and must not offer it in pickers")
    }

    /// Only `en` and its regional forms are English. A bare prefix match would
    /// route anything starting with those letters to the English model.
    func test_language_code_resolution_does_not_prefix_match_unrelated_codes() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.resolve("en_GB").code, "en")
        XCTAssertEqual(settings.resolve("enochian").code, "enochian")
        XCTAssertEqual(settings.resolve("held").code, "held")
    }

    /// Auto-detect was removed: the language is always an explicit choice, and
    /// the toolbar picker iterates `visible`, so this guards its contents too.
    func test_fresh_install_offers_hebrew_and_english() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.visible.map(\.code), ["he", "en"])
        XCTAssertEqual(settings.configured("auto")?.code, "he",
                       "auto is an alias for Hebrew, never an entry of its own")
    }

    /// Someone upgrading from a build that had auto-detect has `"auto"` sitting
    /// in defaults. It must resolve to Hebrew *and* be rewritten, so the stale
    /// value doesn't linger in the plist.
    func test_persisted_auto_migrates_to_hebrew() {
        defaults.set("auto", forKey: "recording.language")

        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.current, .hebrew)
        XCTAssertEqual(defaults.string(forKey: "recording.language"), "he",
                       "The retired value must be rewritten, not just ignored")
    }

    /// A fresh install has no stored value — don't write one just to migrate
    /// nothing (that would make "never chosen" indistinguishable from "chose
    /// Hebrew" for any future first-run logic). The LIST is seeded, though.
    func test_fresh_install_does_not_write_a_language() {
        _ = RecordingLanguageSettings(defaults: defaults)
        XCTAssertNil(defaults.string(forKey: "recording.language"))
        XCTAssertNotNil(defaults.data(forKey: "recording.languages"),
                        "the seeded list is persisted")
    }

    // MARK: - Seeding

    func test_seeding_happens_only_when_the_key_is_absent() throws {
        let russianOnly = [RecordingLanguage(code: "ru", flagEmoji: "🇷🇺")]
        defaults.set(try JSONEncoder().encode(russianOnly), forKey: "recording.languages")

        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.languages.map(\.code), ["ru"],
                       "an existing list must never be reseeded")
        XCTAssertEqual(settings.current.code, "ru")
    }

    func test_undecodable_list_uses_seeds_without_overwriting() {
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: "recording.languages")

        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.visible.map(\.code), ["he", "en"])
        XCTAssertEqual(defaults.data(forKey: "recording.languages"), garbage,
                       "a decode failure must not overwrite what the user had")
    }

    /// A stored active code that is no longer visible — say the list was edited
    /// by an older build — lands on the first visible entry and is rewritten.
    func test_stored_code_outside_the_list_falls_back_to_the_first_visible_entry() {
        defaults.set("ru", forKey: "recording.language")
        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.current.code, "he")
        XCTAssertEqual(defaults.string(forKey: "recording.language"), "he")
    }

    func test_setting_a_language_that_is_not_offered_is_ignored() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        settings.current = RecordingLanguage(code: "ru")
        XCTAssertEqual(settings.current.code, "he",
                       "the active language must always be one the pickers offer")
    }

    // MARK: - Derived properties

    func test_display_name_and_rtl_are_derived() {
        for code in ["ar", "fa", "he"] {
            XCTAssertTrue(RecordingLanguage(code: code).isRTL, "\(code) is RTL")
        }
        for code in ["ru", "en"] {
            XCTAssertFalse(RecordingLanguage(code: code).isRTL, "\(code) is LTR")
        }
        XCTAssertEqual(RecordingLanguage(code: "ru").displayName, "Russian")
        XCTAssertEqual(RecordingLanguage.hebrew.displayName, "Hebrew")
        XCTAssertEqual(RecordingLanguage.english.displayName, "English")
    }

    /// Stored lists from a newer build may lack fields; one bad entry must not
    /// fail the decode and cost the user the whole list.
    func test_decoding_tolerates_missing_optional_fields() throws {
        let json = Data(#"[{"code":"RU"}]"#.utf8)
        let decoded = try JSONDecoder().decode([RecordingLanguage].self, from: json)
        XCTAssertEqual(decoded, [RecordingLanguage(code: "ru")])
    }
}
