import XCTest
import Carbon.HIToolbox
@testable import Mila

@MainActor
final class HotkeySettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "HotkeySettingsTests"

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    func test_fresh_install_returns_compiled_in_defaults() throws {
        let settings = HotkeySettings(defaults: defaults)
        let english = try XCTUnwrap(settings.binding(for: .dictateEnglish))
        let hebrew = try XCTUnwrap(settings.binding(for: .dictateHebrew))
        XCTAssertEqual(english.keyCode, UInt32(kVK_ANSI_2))
        XCTAssertEqual(english.modifiers, UInt32(cmdKey))
        XCTAssertEqual(hebrew.keyCode, UInt32(kVK_ANSI_3))
        XCTAssertEqual(hebrew.modifiers, UInt32(cmdKey))
    }

    func test_set_binding_persists_across_instances() {
        let first = HotkeySettings(defaults: defaults)
        let custom = HotkeyBinding(keyCode: UInt32(kVK_F5),
                                   modifiers: UInt32(cmdKey | shiftKey))
        first.setBinding(custom, for: .dictateEnglish)

        let reloaded = HotkeySettings(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .dictateEnglish), custom)
        XCTAssertEqual(reloaded.binding(for: .dictateHebrew),
                       HotkeyAction.defaults[.dictateHebrew],
                       "Hebrew binding must not be touched when only English changes")
    }

    func test_reset_to_default_clears_persisted_value() {
        let settings = HotkeySettings(defaults: defaults)
        let custom = HotkeyBinding(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey))
        settings.setBinding(custom, for: .dictateEnglish)
        XCTAssertEqual(settings.binding(for: .dictateEnglish), custom)

        settings.resetToDefault(.dictateEnglish)
        XCTAssertEqual(settings.binding(for: .dictateEnglish),
                       HotkeyAction.defaults[.dictateEnglish])

        let reloaded = HotkeySettings(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .dictateEnglish),
                       HotkeyAction.defaults[.dictateEnglish])
    }

    func test_display_name_uses_modifier_glyphs_in_canonical_order() {
        let binding = HotkeyBinding(
            keyCode: UInt32(kVK_ANSI_2),
            modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey)
        )
        XCTAssertEqual(binding.displayName, "⌃⌥⇧⌘2")
    }

    func test_display_name_for_function_keys() {
        let binding = HotkeyBinding(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey))
        XCTAssertEqual(binding.displayName, "⌘F5")
    }

    func test_codable_round_trip() throws {
        let original = HotkeyBinding(keyCode: 42, modifiers: UInt32(cmdKey | optionKey))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyBinding.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Per-language bindings

    /// A language the user adds starts unbound — auto-assigning ⌘4, ⌘5… would
    /// collide with other apps' global shortcuts.
    func test_a_new_language_is_unbound() {
        let settings = HotkeySettings(defaults: defaults)
        XCTAssertNil(settings.binding(for: HotkeyAction(languageCode: "ru")))
    }

    func test_a_new_language_binding_persists_and_reset_unbinds_it() {
        let ru = HotkeyAction(languageCode: "ru")
        let combo = HotkeyBinding(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(cmdKey))
        HotkeySettings(defaults: defaults).setBinding(combo, for: ru)
        XCTAssertNotNil(defaults.data(forKey: "hotkey.dictate.ru"))

        let reloaded = HotkeySettings(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: ru), combo)

        reloaded.resetToDefault(ru)
        XCTAssertNil(reloaded.binding(for: ru), "a user-added language's default is unbound")
        XCTAssertNil(HotkeySettings(defaults: defaults).binding(for: ru))
    }

    func test_action_id_is_the_storage_suffix() {
        XCTAssertEqual(HotkeyAction.dictateHebrew.id, "dictate.he")
        XCTAssertEqual(HotkeyAction(languageCode: "RU"), HotkeyAction(languageCode: "ru"))
        XCTAssertEqual(HotkeyAction(languageCode: "ru").displayLabel, "Russian dictation")
    }

    // MARK: - Legacy keys

    /// Builds with the two-case enum stored custom combos under
    /// `hotkey.dictateHebrew` / `hotkey.dictateEnglish`. Upgrading must not
    /// lose them.
    func test_legacy_custom_binding_is_migrated_to_the_language_key() throws {
        let custom = HotkeyBinding(keyCode: UInt32(kVK_F6), modifiers: UInt32(cmdKey | optionKey))
        defaults.set(try JSONEncoder().encode(custom), forKey: "hotkey.dictateHebrew")

        let settings = HotkeySettings(defaults: defaults)
        XCTAssertEqual(settings.binding(for: .dictateHebrew), custom)
        XCTAssertNotNil(defaults.data(forKey: "hotkey.dictate.he"), "rewritten under the new key")
        XCTAssertNil(defaults.data(forKey: "hotkey.dictateHebrew"), "old key removed")
        XCTAssertEqual(settings.binding(for: .dictateEnglish), HotkeyAction.defaults[.dictateEnglish],
                       "an un-customized language keeps its default")
    }

    func test_no_legacy_keys_means_nothing_is_written() {
        _ = HotkeySettings(defaults: defaults)
        XCTAssertNil(defaults.data(forKey: "hotkey.dictate.he"))
        XCTAssertNil(defaults.data(forKey: "hotkey.dictate.en"))
    }

    func test_a_value_under_the_new_key_wins_over_a_leftover_legacy_key() throws {
        let current = HotkeyBinding(keyCode: UInt32(kVK_F7), modifiers: UInt32(cmdKey))
        let stale = HotkeyBinding(keyCode: UInt32(kVK_F8), modifiers: UInt32(cmdKey))
        defaults.set(try JSONEncoder().encode(current), forKey: "hotkey.dictate.en")
        defaults.set(try JSONEncoder().encode(stale), forKey: "hotkey.dictateEnglish")

        XCTAssertEqual(HotkeySettings(defaults: defaults).binding(for: .dictateEnglish), current)
        XCTAssertNil(defaults.data(forKey: "hotkey.dictateEnglish"))
    }
}

/// `DictationHotkeyBinder` against a recording registrar — real Carbon
/// registrations would grab system-wide combos from inside the test host.
@MainActor
final class DictationHotkeyBinderTests: XCTestCase {

    private final class FakeRegistrar: HotkeyRegistering {
        var live: [HotkeyAction: HotkeyBinding] = [:]
        var handlers: [HotkeyAction: () -> Void] = [:]
        var registeredActions: Set<HotkeyAction> { Set(live.keys) }
        func register(_ action: HotkeyAction, binding: HotkeyBinding,
                      onPressed: @escaping () -> Void) -> Bool {
            live[action] = binding
            handlers[action] = onPressed
            return true
        }
        func unregister(_ action: HotkeyAction) {
            live[action] = nil
            handlers[action] = nil
        }
    }

    private var hotkeyDefaults: UserDefaults!
    private var languageDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        for name in ["DictationHotkeyBinderTests.hotkeys", "DictationHotkeyBinderTests.languages"] {
            UserDefaults().removePersistentDomain(forName: name)
        }
        hotkeyDefaults = UserDefaults(suiteName: "DictationHotkeyBinderTests.hotkeys")
        languageDefaults = UserDefaults(suiteName: "DictationHotkeyBinderTests.languages")
    }

    override func tearDown() async throws {
        hotkeyDefaults.removePersistentDomain(forName: "DictationHotkeyBinderTests.hotkeys")
        languageDefaults.removePersistentDomain(forName: "DictationHotkeyBinderTests.languages")
        try await super.tearDown()
    }

    private let f5 = HotkeyBinding(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey))

    func test_registers_the_seed_languages_on_launch() {
        let registrar = FakeRegistrar()
        let binder = DictationHotkeyBinder(hotkeys: HotkeySettings(defaults: hotkeyDefaults),
                                           languages: RecordingLanguageSettings(defaults: languageDefaults),
                                           registrar: registrar) { _ in }
        XCTAssertEqual(registrar.live, HotkeyAction.defaults)
        _ = binder
    }

    /// The regression: `@Published` emits in `willSet`, so re-registering by
    /// reading `hotkeys.binding(for:)` inside the sink picked up the OLD combo
    /// — a rebind in Settings did nothing until relaunch.
    func test_a_rebind_registers_the_new_combo() {
        let registrar = FakeRegistrar()
        let hotkeys = HotkeySettings(defaults: hotkeyDefaults)
        let binder = DictationHotkeyBinder(hotkeys: hotkeys,
                                           languages: RecordingLanguageSettings(defaults: languageDefaults),
                                           registrar: registrar) { _ in }
        hotkeys.setBinding(f5, for: .dictateEnglish)
        XCTAssertEqual(registrar.live[.dictateEnglish], f5)
        _ = binder
    }

    func test_a_new_language_registers_only_once_it_has_a_binding() {
        let registrar = FakeRegistrar()
        let hotkeys = HotkeySettings(defaults: hotkeyDefaults)
        let languages = RecordingLanguageSettings(defaults: languageDefaults)
        let binder = DictationHotkeyBinder(hotkeys: hotkeys, languages: languages,
                                           registrar: registrar) { _ in }
        let ru = HotkeyAction(languageCode: "ru")

        languages.add(code: "ru")
        XCTAssertNil(registrar.live[ru], "unbound → not registered")

        hotkeys.setBinding(f5, for: ru)
        XCTAssertEqual(registrar.live[ru], f5)
        _ = binder
    }

    /// A removed language stops dictating but keeps its binding, and gets it
    /// back when re-added.
    func test_hiding_a_language_unregisters_it_and_re_adding_restores_it() {
        let registrar = FakeRegistrar()
        let hotkeys = HotkeySettings(defaults: hotkeyDefaults)
        let languages = RecordingLanguageSettings(defaults: languageDefaults)
        let binder = DictationHotkeyBinder(hotkeys: hotkeys, languages: languages,
                                           registrar: registrar) { _ in }

        languages.remove(code: "he")
        XCTAssertNil(registrar.live[.dictateHebrew])
        XCTAssertEqual(hotkeys.binding(for: .dictateHebrew), HotkeyAction.defaults[.dictateHebrew],
                       "the binding itself is kept")

        languages.add(code: "he")
        XCTAssertEqual(registrar.live[.dictateHebrew], HotkeyAction.defaults[.dictateHebrew])
        _ = binder
    }

    func test_pressing_a_hotkey_reports_its_action() {
        let registrar = FakeRegistrar()
        var pressed: [HotkeyAction] = []
        let binder = DictationHotkeyBinder(hotkeys: HotkeySettings(defaults: hotkeyDefaults),
                                           languages: RecordingLanguageSettings(defaults: languageDefaults),
                                           registrar: registrar) { pressed.append($0) }
        registrar.handlers[.dictateHebrew]?()
        XCTAssertEqual(pressed, [.dictateHebrew])
        _ = binder
    }

    /// Two visible languages can end up with the same combo (a hidden one
    /// keeps its binding and is re-added later). The first in list order
    /// keeps it, whatever the dictionary order of `bindings`.
    func test_a_shared_combo_goes_to_the_first_language_in_list_order() {
        let combo = HotkeyAction.defaults[.dictateHebrew]!
        let ru = HotkeyAction(languageCode: "ru")
        let list = RecordingLanguage.seeds + [RecordingLanguage(code: "ru")]
        let bindings: [HotkeyAction: HotkeyBinding] = [ru: combo, .dictateHebrew: combo]

        let wanted = DictationHotkeyBinder.wanted(bindings: bindings, languages: list)
        XCTAssertEqual(wanted[.dictateHebrew], combo)
        XCTAssertNil(wanted[ru])

        let reordered = [RecordingLanguage(code: "ru")] + RecordingLanguage.seeds
        let wanted2 = DictationHotkeyBinder.wanted(bindings: bindings, languages: reordered)
        XCTAssertEqual(wanted2[ru], combo)
        XCTAssertNil(wanted2[.dictateHebrew])
    }
}
