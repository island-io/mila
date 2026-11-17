import Foundation
import Combine
import Carbon.HIToolbox

/// Persists user-customized hotkey bindings (at most one per language) to
/// `UserDefaults` and re-publishes them so the Settings UI can observe edits.
///
/// Bindings are encoded as JSON under the key `hotkey.<action.id>`
/// (`hotkey.dictate.he`). If no binding has been saved, the action's
/// `defaults` value is used — which exists only for the two seed languages; a
/// language the user adds is unbound until they record a shortcut for it.
///
/// Bindings are keyed by language code, not by list position, so a removed
/// (hidden) language keeps its binding here and gets it back when re-added.
@MainActor
final class HotkeySettings: ObservableObject {
    @Published private(set) var bindings: [HotkeyAction: HotkeyBinding] = [:]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        Self.migrateLegacyKeys(in: defaults)

        var initial = HotkeyAction.defaults
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(Self.keyPrefix) {
            let code = String(key.dropFirst(Self.keyPrefix.count))
            let action = HotkeyAction(languageCode: code)
            if let stored = Self.load(action: action, from: defaults) {
                initial[action] = stored
            }
        }
        self.bindings = initial
    }

    /// The combo that dictates in `action`'s language, or nil when unbound.
    func binding(for action: HotkeyAction) -> HotkeyBinding? {
        bindings[action]
    }

    /// Atomically update a single action's binding and persist it.
    func setBinding(_ binding: HotkeyBinding, for action: HotkeyAction) {
        bindings[action] = binding
        Self.save(binding, action: action, into: defaults)
    }

    /// Restore the action to its compiled-in default — which, for a language
    /// the user added, means unbound.
    func resetToDefault(_ action: HotkeyAction) {
        defaults.removeObject(forKey: Self.key(action: action))
        bindings[action] = HotkeyAction.defaults[action]
    }

    // MARK: - Storage

    private static let keyPrefix = "hotkey.dictate."

    private static func key(action: HotkeyAction) -> String {
        "hotkey.\(action.id)"
    }

    /// Custom bindings saved by the two-case-enum builds live under
    /// `hotkey.dictateHebrew` / `hotkey.dictateEnglish`. Move each to its
    /// language-keyed name once, so nobody loses a combo they recorded. A
    /// value already under the new name wins — this build wrote it.
    private static func migrateLegacyKeys(in defaults: UserDefaults) {
        for (action, legacyName) in HotkeyAction.legacyStorageNames {
            let legacyKey = "hotkey.\(legacyName)"
            guard let data = defaults.data(forKey: legacyKey) else { continue }
            if defaults.data(forKey: key(action: action)) == nil {
                defaults.set(data, forKey: key(action: action))
            }
            defaults.removeObject(forKey: legacyKey)
        }
    }

    private static func load(action: HotkeyAction, from defaults: UserDefaults) -> HotkeyBinding? {
        guard let data = defaults.data(forKey: key(action: action)) else { return nil }
        return try? JSONDecoder().decode(HotkeyBinding.self, from: data)
    }

    private static func save(_ binding: HotkeyBinding,
                             action: HotkeyAction,
                             into defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(binding) {
            defaults.set(data, forKey: key(action: action))
        }
    }
}

/// Keeps the live Carbon registrations in step with the language list and the
/// bindings: one hotkey per VISIBLE language that has a binding. A hidden
/// language is unregistered but keeps its binding in `HotkeySettings`.
///
/// Re-registers from the values the publishers EMIT, never by reading the
/// properties back: `@Published` fires in `willSet`, so inside the sink the
/// property still holds the OLD value. Reading it there is how a rebind in
/// Settings used to re-register the previous combo, leaving the new one dead
/// until relaunch.
@MainActor
final class DictationHotkeyBinder {
    private let registrar: HotkeyRegistering
    private let onPressed: (HotkeyAction) -> Void
    private var observer: AnyCancellable?

    init(hotkeys: HotkeySettings,
         languages: RecordingLanguageSettings,
         registrar: HotkeyRegistering,
         onPressed: @escaping (HotkeyAction) -> Void) {
        self.registrar = registrar
        self.onPressed = onPressed
        observer = hotkeys.$bindings
            .combineLatest(languages.$languages)
            .sink { [weak self] bindings, list in
                self?.apply(Self.wanted(bindings: bindings, languages: list))
            }
    }

    /// Which action should be live under which combo.
    ///
    /// A combo goes to the FIRST visible language in list order that has it.
    /// Duplicates are possible: Settings only checks collisions among visible
    /// languages, and a hidden language keeps its binding (or its seed
    /// default), so re-adding it can bring back a combo another language took
    /// meanwhile. Without this, which one Carbon kept would depend on
    /// dictionary order; now the loser is deterministic and shows Settings'
    /// "couldn't be registered" warning.
    static func wanted(bindings: [HotkeyAction: HotkeyBinding],
                       languages: [RecordingLanguage]) -> [HotkeyAction: HotkeyBinding] {
        var out: [HotkeyAction: HotkeyBinding] = [:]
        var taken: Set<HotkeyBinding> = []
        for language in languages where !language.isHidden {
            let action = HotkeyAction(languageCode: language.code)
            if let binding = bindings[action], taken.insert(binding).inserted {
                out[action] = binding
            }
        }
        return out
    }

    private func apply(_ wanted: [HotkeyAction: HotkeyBinding]) {
        for stale in registrar.registeredActions where wanted[stale] == nil {
            registrar.unregister(stale)
        }
        for (action, binding) in wanted {
            registrar.register(action, binding: binding) { [weak self] in
                self?.onPressed(action)
            }
        }
    }
}
