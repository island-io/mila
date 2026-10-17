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

/// The settings an administrator has locked through a configuration profile —
/// the MDM counterpart of a `.milaconfig` (issue #360).
///
/// **Same schema as `.milaconfig`.** The profile's payload for the
/// `io.island.whisper.IslandWhisper` domain uses the same top-level keys
/// (`remoteTranscription`, `recordingLanguage`, `liveAI`, `diarization`,
/// `meetingDetection`) and the same nested field names, so an admin can turn
/// the `.milaconfig` they already hand out into a profile key for key. `version`
/// is not needed (and is ignored): a profile can't be "rejected" the way a
/// double-clicked file can, so the reader simply takes the fields it knows and
/// ignores the rest.
///
/// **Precedence: managed > `.milaconfig` > the user's own setting.** A field
/// present here is *forced*: the settings object holding it starts from this
/// value, never persists a different one, reverts any write that tries, and
/// Settings shows the control disabled with "Managed by your organization".
/// Importing a `.milaconfig` skips managed fields (and says so in the
/// confirmation sheet). A field absent here is not managed at all — the user
/// (or a `.milaconfig`) controls it as before.
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

    /// Nothing managed — the default for every settings object, so tests and
    /// previews behave exactly as before unless they opt in.
    static let empty = ManagedSettings()

    /// The caption Settings shows beside a locked control.
    static let note = "Managed by your organization"

    var isEmpty: Bool { self == Self.empty }

    /// Top-level payload keys. Deliberately identical to `MilaConfig`'s
    /// `CodingKeys` — see the type doc.
    enum Key {
        static let remoteTranscription = "remoteTranscription"
        static let recordingLanguage = "recordingLanguage"
        static let liveAI = "liveAI"
        static let diarization = "diarization"
        static let meetingDetection = "meetingDetection"

        static let all = [remoteTranscription, recordingLanguage, liveAI, diarization, meetingDetection]
    }
}

extension ManagedSettings {
    /// Map a config's present fields onto managed fields. Uses the same
    /// interpretation as `MilaConfigImporter.apply` (`enabled` → backend,
    /// `recordingLanguage` through `RecordingLanguage.fromCode`), so a value
    /// means the same thing whichever channel delivered it.
    init(config: MilaConfig) {
        self.init()
        if let r = config.remoteTranscription {
            backend = r.enabled.map { $0 ? .remote : .local }
            endpoint = r.endpoint
            model = r.model
            englishModel = r.englishModel
            apiKey = r.apiKey
        }
        recordingLanguage = config.recordingLanguage.map(RecordingLanguage.fromCode)
        liveAIEnabled = config.liveAI?.enabled
        liveAIModel = config.liveAI?.model
        diarizationEnabled = config.diarization?.enabled
        meetingDetectionEnabled = config.meetingDetection?.enabled
    }

    /// Read the forced keys from `source`.
    init(source: ManagedPreferencesSource) {
        self.init(config: Self.config(from: source))
    }

    /// The forced payload as a `MilaConfig`, so both channels share one schema.
    ///
    /// Field-by-field and type-checked rather than a JSON round-trip through
    /// `MilaConfig.decode`: one mistyped field (an `enabled` sent as the string
    /// `"true"`) drops only that field, instead of failing the whole section —
    /// or, worse, the whole profile — and silently leaving everything unmanaged.
    static func config(from source: ManagedPreferencesSource) -> MilaConfig {
        var config = MilaConfig(version: MilaConfig.currentVersion)
        var ignored: [String] = []

        func string(_ dict: [String: Any], _ field: String, in section: String) -> String? {
            guard let raw = dict[field] else { return nil }
            if let value = raw as? String { return value }
            ignored.append("\(section).\(field)")
            return nil
        }
        func bool(_ dict: [String: Any], _ field: String, in section: String) -> Bool? {
            guard let raw = dict[field] else { return nil }
            if let value = raw as? Bool { return value }
            ignored.append("\(section).\(field)")
            return nil
        }
        func section(_ key: String) -> [String: Any]? {
            guard let raw = source.forcedValue(forKey: key) else { return nil }
            if let dict = raw as? [String: Any] { return dict }
            ignored.append(key)
            return nil
        }

        if let r = section(Key.remoteTranscription) {
            let s = Key.remoteTranscription
            config.remoteTranscription = .init(enabled: bool(r, "enabled", in: s),
                                               endpoint: string(r, "endpoint", in: s),
                                               model: string(r, "model", in: s),
                                               englishModel: string(r, "englishModel", in: s),
                                               apiKey: string(r, "apiKey", in: s))
        }
        if let raw = source.forcedValue(forKey: Key.recordingLanguage) {
            if let code = raw as? String {
                config.recordingLanguage = code
            } else {
                ignored.append(Key.recordingLanguage)
            }
        }
        if let l = section(Key.liveAI) {
            config.liveAI = .init(enabled: bool(l, "enabled", in: Key.liveAI),
                                  model: string(l, "model", in: Key.liveAI))
        }
        if let d = section(Key.diarization) {
            config.diarization = .init(enabled: bool(d, "enabled", in: Key.diarization))
        }
        if let m = section(Key.meetingDetection) {
            config.meetingDetection = .init(enabled: bool(m, "enabled", in: Key.meetingDetection))
        }

        if !ignored.isEmpty {
            // Key names only — they're Mila's own schema. Values (a server URL,
            // a token) never reach the log.
            Self.log.error("""
                ignored managed preference(s) with the wrong type: \
                \(ignored.joined(separator: ", "), privacy: .public)
                """)
        }
        return config
    }

    /// Key paths of the fields that are managed, for the launch log and the
    /// docs' troubleshooting step. Names only, never values.
    var managedFieldNames: [String] {
        var out: [String] = []
        if backend != nil { out.append("remoteTranscription.enabled") }
        if endpoint != nil { out.append("remoteTranscription.endpoint") }
        if model != nil { out.append("remoteTranscription.model") }
        if englishModel != nil { out.append("remoteTranscription.englishModel") }
        if apiKey != nil { out.append("remoteTranscription.apiKey") }
        if recordingLanguage != nil { out.append("recordingLanguage") }
        if liveAIEnabled != nil { out.append("liveAI.enabled") }
        if liveAIModel != nil { out.append("liveAI.model") }
        if diarizationEnabled != nil { out.append("diarization.enabled") }
        if meetingDetectionEnabled != nil { out.append("meetingDetection.enabled") }
        return out
    }

    /// Read the system's managed preferences once, at launch, and log which
    /// fields are locked.
    static func loadFromSystem() -> ManagedSettings {
        let managed = ManagedSettings(source: SystemManagedPreferences())
        if !managed.isEmpty {
            log.log("""
                managed by configuration profile: \
                \(managed.managedFieldNames.joined(separator: ", "), privacy: .public)
                """)
        }
        return managed
    }

    private static let log = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                    category: "ManagedSettings")
}
