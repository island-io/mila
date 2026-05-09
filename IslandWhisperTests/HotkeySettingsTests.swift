import XCTest
import Carbon.HIToolbox
@testable import IslandWhisper

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

    func test_fresh_install_returns_compiled_in_defaults() {
        let settings = HotkeySettings(defaults: defaults)
        let english = settings.binding(for: .dictateEnglish)
        let hebrew = settings.binding(for: .dictateHebrew)
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
                       HotkeyAction.defaults[.dictateHebrew]!,
                       "Hebrew binding must not be touched when only English changes")
    }

    func test_reset_to_default_clears_persisted_value() {
        let settings = HotkeySettings(defaults: defaults)
        let custom = HotkeyBinding(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey))
        settings.setBinding(custom, for: .dictateEnglish)
        XCTAssertEqual(settings.binding(for: .dictateEnglish), custom)

        settings.resetToDefault(.dictateEnglish)
        XCTAssertEqual(settings.binding(for: .dictateEnglish),
                       HotkeyAction.defaults[.dictateEnglish]!)

        let reloaded = HotkeySettings(defaults: defaults)
        XCTAssertEqual(reloaded.binding(for: .dictateEnglish),
                       HotkeyAction.defaults[.dictateEnglish]!)
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
}
