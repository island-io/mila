import XCTest
import Combine
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

    // MARK: - Editing

    func test_add_appends_a_visible_entry_with_defaults() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        let added = settings.add(code: "ru")
        XCTAssertEqual(added, RecordingLanguage(code: "ru"))
        XCTAssertEqual(settings.visible.map(\.code), ["he", "en", "ru"])
        XCTAssertEqual(settings.configured("ru")?.flagEmoji, "")
        XCTAssertNil(settings.configured("ru")?.modelName, "multilingual default")
    }

    func test_add_normalizes_case() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        settings.add(code: "RU")
        XCTAssertEqual(settings.visible.last?.code, "ru")
    }

    /// The stored code reaches whisper verbatim, so only codes whisper knows
    /// can be added — a regional variant or a typo would not transcribe.
    func test_add_rejects_codes_whisper_does_not_support() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        for code in ["ru-RU", "rus", "auto", "", "klingon"] {
            XCTAssertNil(settings.add(code: code), "\(code) must be rejected")
        }
        XCTAssertEqual(settings.visible.map(\.code), ["he", "en"])
    }

    func test_add_of_a_visible_code_is_a_no_op() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.add(code: "he"), .hebrew)
        XCTAssertEqual(settings.languages.map(\.code), ["he", "en"], "no duplicate entry")
    }

    func test_remove_hides_and_keeps_the_record() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertTrue(settings.remove(code: "en"))
        XCTAssertEqual(settings.visible.map(\.code), ["he"])
        XCTAssertEqual(settings.languages.first { $0.code == "en" }?.isHidden, true)
        XCTAssertNil(settings.configured("en"), "no longer offered")
    }

    /// Remove-then-add is a lossless round trip: the flag and model the user
    /// set come back, and the entry keeps its place in the list.
    func test_adding_a_hidden_code_unhides_it_with_its_settings() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        settings.add(code: "ru")
        settings.update(RecordingLanguage(code: "ru", flagEmoji: "🇷🇺",
                                          modelName: WhisperModel.ivritLarge.name))
        settings.remove(code: "ru")

        let back = settings.add(code: "ru")
        XCTAssertEqual(back?.flagEmoji, "🇷🇺")
        XCTAssertEqual(back?.modelName, WhisperModel.ivritLarge.name)
        XCTAssertEqual(settings.languages.map(\.code), ["he", "en", "ru"])
        XCTAssertEqual(settings.visible.map(\.code), ["he", "en", "ru"])
    }

    func test_the_last_visible_language_cannot_be_removed() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertTrue(settings.remove(code: "en"))
        XCTAssertFalse(settings.remove(code: "he"))
        XCTAssertEqual(settings.visible.map(\.code), ["he"])
    }

    func test_removing_an_unknown_or_hidden_code_is_refused() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertFalse(settings.remove(code: "ru"))
        settings.remove(code: "en")
        XCTAssertFalse(settings.remove(code: "en"))
    }

    func test_removing_the_active_language_repoints_to_the_first_visible_entry() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        settings.current = .english
        settings.remove(code: "en")
        XCTAssertEqual(settings.current.code, "he")
        XCTAssertEqual(defaults.string(forKey: "recording.language"), "he")
    }

    func test_edits_persist_across_instances() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        settings.add(code: "ru")
        settings.update(RecordingLanguage(code: "ru", flagEmoji: "🇷🇺"))
        settings.remove(code: "en")

        let reloaded = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(reloaded.visible.map(\.code), ["he", "ru"])
        XCTAssertEqual(reloaded.configured("ru")?.flagEmoji, "🇷🇺")
        XCTAssertEqual(reloaded.resolve("en").isHidden, true)
    }

    /// `update` edits flag and model only — it is not a back door around
    /// remove's last-visible guard or add's whisper check.
    func test_update_changes_flag_and_model_but_not_visibility() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        settings.update(RecordingLanguage(code: "he", flagEmoji: "✡️",
                                          modelName: WhisperModel.openaiTurbo.name,
                                          isHidden: true))
        let he = settings.resolve("he")
        XCTAssertEqual(he.flagEmoji, "✡️")
        XCTAssertEqual(he.modelName, WhisperModel.openaiTurbo.name)
        XCTAssertFalse(he.isHidden)
        XCTAssertEqual(settings.current.flagEmoji, "✡️", "the active language reflects the edit")

        settings.update(RecordingLanguage(code: "ru", flagEmoji: "🇷🇺"))
        XCTAssertFalse(settings.languages.contains { $0.code == "ru" },
                       "update does not add")
    }

    /// Each edit is ONE publish: the list is on an App-level @StateObject,
    /// where every publish re-diffs every scene (#280).
    func test_each_edit_publishes_once() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        var publishes = 0
        let sub = settings.objectWillChange.sink { publishes += 1 }
        settings.add(code: "ru")
        XCTAssertEqual(publishes, 1)
        settings.update(RecordingLanguage(code: "ru", flagEmoji: "🇷🇺"))
        XCTAssertEqual(publishes, 2)
        settings.remove(code: "ru")
        XCTAssertEqual(publishes, 3)
        sub.cancel()
    }

    // MARK: - Removing a language must not break its recordings

    /// The regression this whole design exists to prevent: removing Hebrew
    /// must leave every `he` recording displaying as Hebrew, right-to-left,
    /// and re-transcribing on ivrit.ai.
    func test_removing_hebrew_keeps_hebrew_recordings_resolving() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        settings.remove(code: "he")

        let he = settings.resolve("he")
        XCTAssertEqual(he.displayName, "Hebrew")
        XCTAssertEqual(he.flagEmoji, "🇮🇱")
        XCTAssertTrue(he.isRTL)
        XCTAssertEqual(he.modelName, WhisperModel.ivritLarge.name)
        XCTAssertEqual(settings.resolve("iw").code, "he")
        XCTAssertNil(settings.configured("he"), "but no longer offered for new recordings")
    }

    /// Same for a user-added RTL language — the case a fallback table of the
    /// two seeds could never have covered.
    func test_removing_a_user_added_rtl_language_keeps_its_recordings_rtl() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        settings.add(code: "ar")
        settings.update(RecordingLanguage(code: "ar", flagEmoji: "🇸🇦"))
        settings.remove(code: "ar")

        let ar = settings.resolve("ar")
        XCTAssertTrue(ar.isRTL)
        XCTAssertEqual(ar.flagEmoji, "🇸🇦")
        XCTAssertEqual(ar.displayName, "Arabic")
    }

    // MARK: - Re-transcribe targets

    /// Every other offered language, in list order — not just the first one,
    /// which left a third language unreachable from the menus.
    func test_retranscribe_targets_are_the_visible_list_minus_the_recordings_own() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        settings.add(code: "ru")
        XCTAssertEqual(settings.retranscribeTargets(for: "he").map(\.code), ["en", "ru"])
        XCTAssertEqual(settings.retranscribeTargets(for: "ru").map(\.code), ["he", "en"])
    }

    /// Aliases and regional variants count as the recording's own language.
    func test_retranscribe_targets_treat_variants_and_legacy_codes_as_own() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.retranscribeTargets(for: "en-US").map(\.code), ["he"])
        XCTAssertEqual(settings.retranscribeTargets(for: "auto").map(\.code), ["en"])
        XCTAssertEqual(settings.retranscribeTargets(for: "iw").map(\.code), ["en"])
    }

    /// A recording in a removed language: every offered language is a
    /// target. (Re-running in its OWN language is the separate "current"
    /// entry, which works whether or not the language is still offered.)
    func test_a_recording_in_a_hidden_language_can_target_every_visible_one() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        settings.add(code: "ru")
        settings.remove(code: "ru")
        XCTAssertEqual(settings.retranscribeTargets(for: "ru").map(\.code), ["he", "en"])
    }

    /// A shared recording's language may never have been in this user's
    /// list at all.
    func test_a_recording_in_an_unknown_language_can_target_every_visible_one() {
        let settings = RecordingLanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.retranscribeTargets(for: "fr").map(\.code), ["he", "en"])
    }

    func test_label_omits_the_flag_when_there_is_none() {
        XCTAssertEqual(RecordingLanguage.hebrew.label, "🇮🇱 Hebrew")
        XCTAssertEqual(RecordingLanguage(code: "ru").label, "Russian")
    }
}
