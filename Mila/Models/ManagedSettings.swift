import Foundation
import os

/// Where Mila reads administrator-**forced** preferences from.
///
/// A seam, not an abstraction for its own sake: production reads the real
/// managed-preferences domain (`SystemManagedPreferences`), and tests inject a
/// dictionary so they never touch — or depend on — whatever profile happens to
/// be installed on the machine running them.
protocol ManagedPreferencesSource {
    /// The value an administrator has *forced* for `key`, or `nil` when the key
    /// is not forced. A value that is merely present (a `defaults write`, the
    /// app's own plist) is **not** forced and must come back `nil`: only a
    /// configuration profile can lock a setting.
    func forcedValue(forKey key: String) -> Any?
}

/// Reads forced preferences for the running app's own domain — the bundle id,
/// `io.island.whisper.IslandWhisper` — as delivered by a configuration profile
/// (MDM, or a manually installed `.mobileconfig`). macOS materialises those
/// under `/Library/Managed Preferences/` and `cfprefsd` layers them on top of
/// every other preference source; `CFPreferencesAppValueIsForced` is the
/// documented way to ask whether a key came from there.
struct SystemManagedPreferences: ManagedPreferencesSource {
    func forcedValue(forKey key: String) -> Any? {
        let cfKey = key as CFString
        guard CFPreferencesAppValueIsForced(cfKey, kCFPreferencesCurrentApplication) else {
            return nil
        }
        let value: CFPropertyList? = CFPreferencesCopyAppValue(cfKey, kCFPreferencesCurrentApplication)
        return value
    }
}

/// One manageable setting. **The single list** every managed-settings code path
/// iterates — the parser, `.milaconfig` precedence in `MilaConfigImporter`, the
/// launch log and the tests — so a field can't be handled in one place and
/// forgotten in another. The raw value is the field's path in the `.milaconfig`
/// schema (`section.field`, or a bare top-level key).
enum ManagedField: String, CaseIterable, Sendable {
    case backend = "remoteTranscription.enabled"
    case endpoint = "remoteTranscription.endpoint"
    case model = "remoteTranscription.model"
    case englishModel = "remoteTranscription.englishModel"
    case apiKey = "remoteTranscription.apiKey"
    case recordingLanguage = "recordingLanguage"
    case liveAIEnabled = "liveAI.enabled"
    case liveAIModel = "liveAI.model"
    case diarizationEnabled = "diarization.enabled"
    case meetingDetectionEnabled = "meetingDetection.enabled"

    /// The `.milaconfig` section holding this field, or `nil` for a top-level
    /// key; and the field's name within it.
    var section: String? {
        let parts = rawValue.split(separator: ".", maxSplits: 1)
        return parts.count == 2 ? String(parts[0]) : nil
    }

    var name: String {
        let parts = rawValue.split(separator: ".", maxSplits: 1)
        return String(parts[parts.count - 1])
    }

    /// Mila's own `UserDefaults` key for this setting (`nil` for the API key,
    /// which lives in the Keychain).
    ///
    /// Recognised as a managed key in its own right: `cfprefsd` serves a forced
    /// value to *every* reader of the domain, so a profile that forces
    /// `liveAI.enabled` or `remote.endpoint` directly overrides the setting
    /// whether or not Mila knows. Treating it as managed is what keeps that
    /// case from looking like an enabled control whose edits silently vanish.
    /// `ManagedSettingsEnforcementTests` checks each one against the key the
    /// settings object really writes.
    var storageKey: String? {
        switch self {
        case .backend: return "transcription.backend"
        case .endpoint: return "remote.endpoint"
        case .model: return "remote.model"
        case .englishModel: return "remote.model.en"
        case .apiKey: return nil
        case .recordingLanguage: return "recording.language"
        case .liveAIEnabled: return "liveAI.enabled"
        case .liveAIModel: return "liveAI.model"
        case .diarizationEnabled: return "diarization.enabled"
        case .meetingDetectionEnabled: return "meetingDetection.enabled"
        }
    }

    /// The row label in the `.milaconfig` confirmation sheet.
    var label: String {
        switch self {
        case .backend: return "Transcription"
        case .endpoint: return "Server URL"
        case .model: return "Model"
        case .englishModel: return "English model"
        case .apiKey: return "API key"
        case .recordingLanguage: return "Recording language"
        case .liveAIEnabled: return "Live AI"
        case .liveAIModel: return "Live AI model"
        case .diarizationEnabled: return "Speaker diarization"
        case .meetingDetectionEnabled: return "Meeting detection"
        }
    }

    /// Whether `config` sets this field.
    func isPresent(in config: MilaConfig) -> Bool {
        switch self {
        case .backend: return config.remoteTranscription?.enabled != nil
        case .endpoint: return config.remoteTranscription?.endpoint != nil
        case .model: return config.remoteTranscription?.model != nil
        case .englishModel: return config.remoteTranscription?.englishModel != nil
        case .apiKey: return config.remoteTranscription?.apiKey != nil
        case .recordingLanguage: return config.recordingLanguage != nil
        case .liveAIEnabled: return config.liveAI?.enabled != nil
        case .liveAIModel: return config.liveAI?.model != nil
        case .diarizationEnabled: return config.diarization?.enabled != nil
        case .meetingDetectionEnabled: return config.meetingDetection?.enabled != nil
        }
    }

    /// Clear this field in `config`.
    func remove(from config: inout MilaConfig) {
        switch self {
        case .backend: config.remoteTranscription?.enabled = nil
        case .endpoint: config.remoteTranscription?.endpoint = nil
        case .model: config.remoteTranscription?.model = nil
        case .englishModel: config.remoteTranscription?.englishModel = nil
        case .apiKey: config.remoteTranscription?.apiKey = nil
        case .recordingLanguage: config.recordingLanguage = nil
        case .liveAIEnabled: config.liveAI?.enabled = nil
        case .liveAIModel: config.liveAI?.model = nil
        case .diarizationEnabled: config.diarization?.enabled = nil
        case .meetingDetectionEnabled: config.meetingDetection?.enabled = nil
        }
    }
}

/// The settings an administrator has locked through a configuration profile —
/// the MDM counterpart of a `.milaconfig` (issue #360).
///
/// **Same schema as `.milaconfig`.** The profile's payload for the
/// `io.island.whisper.IslandWhisper` domain uses the same nested dictionaries
/// (`remoteTranscription`, `liveAI`, `diarization`, `meetingDetection`) and the
/// same top-level `recordingLanguage`, so an admin can turn the `.milaconfig`
/// they already hand out into a profile key for key. `version` is not needed
/// (and is ignored). A forced *flat* key — the dotted path written as one key,
/// or Mila's own `UserDefaults` key (`ManagedField.storageKey`) — is honoured
/// too, because it overrides the setting regardless.
///
/// **Precedence: managed > `.milaconfig` > the user's own setting.** A field
/// present here is *forced*: the settings object holding it starts from this
/// value and its setter refuses every write (nothing is stored, published or
/// persisted), and Settings shows the control disabled with "Managed by your
/// organization". Importing a `.milaconfig` skips managed fields (and says so
/// in the confirmation sheet). A field absent here is not managed at all.
///
/// The user's own stored value is left untouched underneath, so removing the
/// profile restores what they had. Read once at launch: a profile that changes
/// while Mila is running takes effect on the next launch.
struct ManagedSettings: Equatable, Sendable {
    var backend: TranscriptionBackend?
    var endpoint: String?
    var model: String?
    var englishModel: String?
    /// Bearer token for the remote backend. When managed it lives in memory
    /// only — never written to the Keychain, and the Keychain is never read
    /// (so no "confidential information" prompt either).
    var apiKey: String?
    var recordingLanguage: RecordingLanguage?
    var liveAIEnabled: Bool?
    var liveAIModel: String?
    var diarizationEnabled: Bool?
    var meetingDetectionEnabled: Bool?
    /// Fields a profile forces under at least one recognised key, but with no
    /// value Mila can use (wrong type, unknown language). Still **locked**: the
    /// administrator meant to manage them, and a forced flat key overrides the
    /// setting for every reader whatever Mila thinks of it — so treating them
    /// as unmanaged would show an editable control whose edits never stick.
    /// The setting keeps the value it already had; writes are refused.
    var lockedWithoutValue: Set<ManagedField> = []

    /// Nothing managed — the default for every settings object, so tests and
    /// previews behave exactly as before unless they opt in.
    static let empty = ManagedSettings()

    /// The caption Settings shows beside a locked control.
    static let note = "Managed by your organization"

    var isEmpty: Bool { self == Self.empty }

    /// Whether `field` is locked. The one question every setter, view and the
    /// importer ask.
    func isManaged(_ field: ManagedField) -> Bool {
        lockedWithoutValue.contains(field) || hasValue(for: field)
    }

    private func hasValue(for field: ManagedField) -> Bool {
        switch field {
        case .backend: return backend != nil
        case .endpoint: return endpoint != nil
        case .model: return model != nil
        case .englishModel: return englishModel != nil
        case .apiKey: return apiKey != nil
        case .recordingLanguage: return recordingLanguage != nil
        case .liveAIEnabled: return liveAIEnabled != nil
        case .liveAIModel: return liveAIModel != nil
        case .diarizationEnabled: return diarizationEnabled != nil
        case .meetingDetectionEnabled: return meetingDetectionEnabled != nil
        }
    }

    /// The managed fields, in `ManagedField` order.
    var managedFields: [ManagedField] { ManagedField.allCases.filter { isManaged($0) } }
}

extension ManagedSettings {
    /// Map a config's present fields onto managed fields, with the same
    /// interpretation as `MilaConfigImporter.apply` (`enabled` → backend) —
    /// except the language, which is validated strictly (`strictLanguage`).
    init(config: MilaConfig) {
        self.init()
        if let r = config.remoteTranscription {
            backend = r.enabled.map { $0 ? .remote : .local }
            endpoint = r.endpoint
            model = r.model
            englishModel = r.englishModel
            apiKey = r.apiKey
        }
        recordingLanguage = config.recordingLanguage.flatMap(Self.strictLanguage)
        liveAIEnabled = config.liveAI?.enabled
        liveAIModel = config.liveAI?.model
        diarizationEnabled = config.diarization?.enabled
        meetingDetectionEnabled = config.meetingDetection?.enabled
    }

    /// Read the forced keys from `source`, logging (by key name only) any that
    /// were present but unusable.
    init(source: ManagedPreferencesSource) {
        let (settings, ignored) = Self.parse(source)
        self = settings
        if !ignored.isEmpty {
            // Key names only — they're Mila's own schema. Values (a server URL,
            // a token) never reach the log.
            Self.log.error("""
                ignored managed preference value(s) with a wrong type or unknown value \
                (the setting stays locked at its current value): \
                \(ignored.joined(separator: ", "), privacy: .public)
                """)
        }
    }

    /// The forced settings in `source`, plus the keys that were forced but
    /// ignored.
    ///
    /// For each field, in order: the nested `.milaconfig`-shaped key
    /// (`liveAI` → `enabled`), then the dotted path forced as one flat key
    /// (`liveAI.enabled`), then Mila's own storage key — the first VALID one
    /// wins. Field by field and type-checked, so one bad value affects only
    /// its own field. A field forced only with unusable values is still locked
    /// (`lockedWithoutValue`), and every rejected key is reported.
    static func parse(_ source: ManagedPreferencesSource) -> (ManagedSettings, ignored: [String]) {
        var settings = ManagedSettings()
        var ignored: [String] = []

        // Each section is fetched once; a forced section that isn't a
        // dictionary is reported once and contributes nothing.
        var sections: [String: [String: Any]] = [:]
        for section in Set(ManagedField.allCases.compactMap(\.section)).sorted() {
            guard let raw = source.forcedValue(forKey: section) else { continue }
            if let dict = raw as? [String: Any] {
                sections[section] = dict
            } else {
                ignored.append(section)
            }
        }

        for field in ManagedField.allCases {
            var candidates: [(key: String, value: Any?, isStorageKey: Bool)] = []
            if let section = field.section {
                candidates.append((key: field.rawValue, value: sections[section]?[field.name], isStorageKey: false))
            }
            // The dotted path as a flat key; for a top-level field this is
            // the nested key itself.
            candidates.append((key: field.rawValue, value: source.forcedValue(forKey: field.rawValue), isStorageKey: false))
            if let storageKey = field.storageKey, storageKey != field.rawValue {
                candidates.append((key: storageKey, value: source.forcedValue(forKey: storageKey), isStorageKey: true))
            }
            // Try every forced candidate in order: a mistyped nested value must
            // not hide a valid flat key that cfprefsd is forcing anyway.
            var anyForced = false
            var assigned = false
            for candidate in candidates {
                guard let raw = candidate.value else { continue }
                anyForced = true
                if settings.assign(field, raw: raw, fromStorageKey: candidate.isStorageKey) {
                    assigned = true
                    break
                }
                ignored.append(candidate.key)
            }
            if anyForced && !assigned {
                settings.lockedWithoutValue.insert(field)
            }
        }
        return (settings, ignored)
    }

    /// Set `field` from a raw plist value. `false` when the value has the
    /// wrong type or isn't one Mila recognises — the field then stays
    /// unmanaged.
    private mutating func assign(_ field: ManagedField, raw: Any, fromStorageKey: Bool) -> Bool {
        switch field {
        case .backend:
            if fromStorageKey {
                // Mila's own key holds the backend's raw value, not a Bool.
                guard let s = raw as? String, let b = TranscriptionBackend(rawValue: s) else { return false }
                backend = b
            } else {
                guard let on = raw as? Bool else { return false }
                backend = on ? .remote : .local
            }
        case .endpoint:
            guard let s = raw as? String else { return false }
            endpoint = s
        case .model:
            guard let s = raw as? String else { return false }
            model = s
        case .englishModel:
            guard let s = raw as? String else { return false }
            englishModel = s
        case .apiKey:
            guard let s = raw as? String else { return false }
            apiKey = s
        case .recordingLanguage:
            guard let s = raw as? String, let language = Self.strictLanguage(s) else { return false }
            recordingLanguage = language
        case .liveAIEnabled:
            guard let on = raw as? Bool else { return false }
            liveAIEnabled = on
        case .liveAIModel:
            guard let s = raw as? String else { return false }
            liveAIModel = s
        case .diarizationEnabled:
            guard let on = raw as? Bool else { return false }
            diarizationEnabled = on
        case .meetingDetectionEnabled:
            guard let on = raw as? Bool else { return false }
            meetingDetectionEnabled = on
        }
        return true
    }

    /// A language code an administrator may lock: `he`/`iw`/`en` or a regional
    /// form (`en-US`, `he_IL`). Stricter than `RecordingLanguage.fromCode`, which
    /// reads anything unknown as Hebrew — right for legacy recordings, wrong for
    /// a lock, where a typo would silently pin every user to Hebrew. Unknown
    /// values are dropped (and logged) instead.
    static func strictLanguage(_ code: String) -> RecordingLanguage? {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = normalized.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { String($0) } ?? ""
        switch base {
        case "he", "iw": return .hebrew
        case "en": return .english
        default: return nil
        }
    }

    /// Read the system's managed preferences once, at launch, and log which
    /// fields are locked (names only, never values).
    static func loadFromSystem() -> ManagedSettings {
        let managed = ManagedSettings(source: SystemManagedPreferences())
        if !managed.isEmpty {
            log.log("""
                managed by configuration profile: \
                \(managed.managedFields.map(\.rawValue).joined(separator: ", "), privacy: .public)
                """)
        }
        return managed
    }

    private static let log = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                    category: "ManagedSettings")
}
