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

    func test_other_returns_opposite_language() {
        XCTAssertEqual(RecordingLanguage.hebrew.other, .english)
        XCTAssertEqual(RecordingLanguage.english.other, .hebrew)
    }

    /// We render flag emoji in the toolbar — make sure they're stable so a
    /// future "let's localize the picker" change doesn't silently strip them.
    func test_flag_emojis_are_stable() {
        XCTAssertEqual(RecordingLanguage.hebrew.flagEmoji, "🇮🇱")
        XCTAssertEqual(RecordingLanguage.english.flagEmoji, "🇬🇧")
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
    }

    /// Unknown / future language codes fall back to Hebrew rather than
    /// crashing — recordings created before this struct existed are tagged
    /// "he", and the UI should treat anything unrecognized the same way.
    func test_unknown_language_code_falls_back_to_hebrew() {
        XCTAssertEqual(RecordingLanguage.fromCode("fr"), .hebrew)
        XCTAssertEqual(RecordingLanguage.fromCode(""), .hebrew)
    }

    /// Only `en` and its regional forms are English. A bare prefix match would
    /// route anything starting with those letters to the English model, against
    /// the documented "unrecognised → Hebrew" contract.
    func test_language_code_decoding_does_not_prefix_match_unrelated_codes() {
        XCTAssertEqual(RecordingLanguage.fromCode("en_GB"), .english)
        XCTAssertEqual(RecordingLanguage.fromCode("enochian"), .hebrew)
        XCTAssertEqual(RecordingLanguage.fromCode("held"), .hebrew,
                       "Unrecognised codes land on Hebrew either way, but not via a prefix match")
    }

    /// Auto-detect was removed: the language is always an explicit choice, and
    /// the toolbar picker is `allCases`-driven, so this guards the picker's
    /// contents too.
    func test_only_hebrew_and_english_are_offered() {
        XCTAssertEqual(RecordingLanguage.allCases, [.hebrew, .english])
        XCTAssertNil(RecordingLanguage(rawValue: "auto"))
    }

    /// A recording tagged by an older build still carries `"auto"`; the UI must
    /// read it as Hebrew rather than crashing or showing a blank language.
    func test_legacy_auto_code_reads_as_hebrew() {
        XCTAssertEqual(RecordingLanguage.fromCode("auto"), .hebrew)
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
    /// Hebrew" for any future first-run logic).
    func test_fresh_install_does_not_write_a_language() {
        _ = RecordingLanguageSettings(defaults: defaults)
        XCTAssertNil(defaults.string(forKey: "recording.language"))
    }
}
