import XCTest
import Combine
@testable import Mila

/// A stand-in for the system's managed-preferences domain. Holds only what a
/// configuration profile would *force*; tests never read the real one, so a
/// profile installed on the machine running them can't change the outcome.
private struct FakeManagedPreferences: ManagedPreferencesSource {
    var forced: [String: Any] = [:]
    func forcedValue(forKey key: String) -> Any? { forced[key] }
}

// MARK: - Reading the payload

final class ManagedSettingsParsingTests: XCTestCase {

    func test_noForcedKeys_isEmpty() {
        let managed = ManagedSettings(source: FakeManagedPreferences())
        XCTAssertTrue(managed.isEmpty)
        XCTAssertEqual(managed, .empty)
        XCTAssertTrue(managed.managedFields.isEmpty)
    }

    func test_readsEveryMilaconfigKey_nestedLikeAMilaconfig() {
        // Shaped exactly like a `.milaconfig` (minus `version`), with values as
        // a profile delivers them: CFBoolean/NSNumber and NSString, not Swift
        // literals.
        let source = FakeManagedPreferences(forced: [
            "remoteTranscription": [
                "enabled": NSNumber(value: true),
                "endpoint": NSString(string: "https://asr.example.com/v1"),
                "model": "ivrit-ai/whisper-large-v3-turbo-ct2",
                "englishModel": "deepdml/faster-whisper-large-v3-turbo-ct2",
                "apiKey": "org-token",
            ] as NSDictionary,
            "recordingLanguage": "en",
            "liveAI": ["enabled": NSNumber(value: false), "model": "claude-haiku"] as NSDictionary,
            "diarization": ["enabled": NSNumber(value: true)] as NSDictionary,
            "meetingDetection": ["enabled": NSNumber(value: false)] as NSDictionary,
        ])

        let managed = ManagedSettings(source: source)
        XCTAssertEqual(managed.backend, .remote)
        XCTAssertEqual(managed.endpoint, "https://asr.example.com/v1")
        XCTAssertEqual(managed.model, "ivrit-ai/whisper-large-v3-turbo-ct2")
        XCTAssertEqual(managed.englishModel, "deepdml/faster-whisper-large-v3-turbo-ct2")
        XCTAssertEqual(managed.apiKey, "org-token")
        XCTAssertEqual(managed.recordingLanguage, .english)
        XCTAssertEqual(managed.liveAIEnabled, false)
        XCTAssertEqual(managed.liveAIModel, "claude-haiku")
        XCTAssertEqual(managed.diarizationEnabled, true)
        XCTAssertEqual(managed.meetingDetectionEnabled, false)
        XCTAssertEqual(managed.managedFields, ManagedField.allCases)
    }

    func test_partialSection_managesOnlyThePresentFields() {
        let source = FakeManagedPreferences(forced: [
            "remoteTranscription": ["endpoint": "https://asr.example.com/v1"] as [String: Any],
        ])
        let managed = ManagedSettings(source: source)
        XCTAssertEqual(managed.endpoint, "https://asr.example.com/v1")
        XCTAssertNil(managed.backend, "Absent `enabled` must leave the backend to the user")
        XCTAssertEqual(managed.managedFields, [.endpoint])
    }

    func test_enabledFalse_managesTheBackendAsLocal() {
        let managed = ManagedSettings(source: FakeManagedPreferences(forced: [
            "remoteTranscription": ["enabled": false] as [String: Any],
        ]))
        XCTAssertEqual(managed.backend, .local)
    }

    func test_wrongTypes_lockWithoutAValue_andAreReportedByKeyName() {
        let source = FakeManagedPreferences(forced: [
            "remoteTranscription": [
                "enabled": "true",                         // string, not bool
                "endpoint": "https://asr.example.com/v1",  // fine
                "model": 42,                               // number, not string
            ] as [String: Any],
            "diarization": "on",                            // not a dictionary
            "recordingLanguage": 1,                         // not a string
            "meetingDetection": ["enabled": true] as [String: Any], // fine
        ])
        let (managed, ignored) = ManagedSettings.parse(source)
        XCTAssertNil(managed.backend)
        XCTAssertNil(managed.model)
        XCTAssertNil(managed.recordingLanguage)
        // Forced but unusable: still locked, so the control can't pretend the
        // user is in charge of it. The malformed `diarization` section names no
        // field, so it locks nothing.
        XCTAssertEqual(managed.lockedWithoutValue, [.backend, .model, .recordingLanguage])
        XCTAssertEqual(managed.managedFields,
                       [.backend, .endpoint, .model, .recordingLanguage, .meetingDetectionEnabled])
        XCTAssertEqual(Set(ignored), ["remoteTranscription.enabled", "remoteTranscription.model",
                                      "diarization", "recordingLanguage"])
    }

    /// A key forced flat — the dotted path as one key, or Mila's own storage
    /// key — overrides the setting for every reader of the domain, so it must
    /// count as managed; otherwise the control stays enabled and the user's
    /// edits silently don't stick.
    func test_flatDottedKeys_areManagedToo() {
        let managed = ManagedSettings(source: FakeManagedPreferences(forced: [
            "diarization.enabled": true,
            "liveAI.model": "org-live",
            "remoteTranscription.endpoint": "https://asr.example.com/v1",
        ]))
        XCTAssertEqual(managed.diarizationEnabled, true)
        XCTAssertEqual(managed.liveAIModel, "org-live")
        XCTAssertEqual(managed.endpoint, "https://asr.example.com/v1")
        XCTAssertEqual(managed.managedFields, [.endpoint, .liveAIModel, .diarizationEnabled])
    }

    func test_milasOwnStorageKeys_areManagedToo() {
        let (managed, ignored) = ManagedSettings.parse(FakeManagedPreferences(forced: [
            "transcription.backend": "remote",
            "remote.endpoint": "https://asr.example.com/v1",
            "remote.model.en": "",
            "recording.language": "he",
        ]))
        XCTAssertEqual(managed.backend, .remote)
        XCTAssertEqual(managed.endpoint, "https://asr.example.com/v1")
        XCTAssertEqual(managed.englishModel, "")
        XCTAssertEqual(managed.recordingLanguage, .hebrew)
        XCTAssertTrue(ignored.isEmpty)

        let (bogus, bogusIgnored) = ManagedSettings.parse(FakeManagedPreferences(forced: [
            "transcription.backend": "cloud",
        ]))
        XCTAssertNil(bogus.backend)
        XCTAssertTrue(bogus.isManaged(.backend), "Forced, so locked even though the value is unusable")
        XCTAssertEqual(bogusIgnored, ["transcription.backend"])
    }

    /// Bugbot on #369: the first forced candidate used to win even when it was
    /// rejected, so a mistyped nested value hid a valid flat key that cfprefsd
    /// forces anyway — the field read as unmanaged while edits never stuck.
    func test_rejectedCandidate_fallsThroughToTheNextForcedKey() {
        let (managed, ignored) = ManagedSettings.parse(FakeManagedPreferences(forced: [
            "remoteTranscription": ["enabled": "yes", "model": 7] as [String: Any],
            "transcription.backend": "remote",
            "remote.model": "org-model",
        ]))
        XCTAssertEqual(managed.backend, .remote)
        XCTAssertEqual(managed.model, "org-model")
        XCTAssertTrue(managed.lockedWithoutValue.isEmpty)
        XCTAssertEqual(Set(ignored), ["remoteTranscription.enabled", "remoteTranscription.model"])
    }

    func test_everyCandidateRejected_stillLocksTheField() {
        let (managed, ignored) = ManagedSettings.parse(FakeManagedPreferences(forced: [
            "liveAI": ["enabled": "yes"] as [String: Any],
            "remoteTranscription.endpoint": 42,
            "remote.endpoint": false,
        ]))
        XCTAssertNil(managed.liveAIEnabled)
        XCTAssertNil(managed.endpoint)
        XCTAssertTrue(managed.isManaged(.liveAIEnabled))
        XCTAssertTrue(managed.isManaged(.endpoint))
        XCTAssertEqual(managed.managedFields, [.endpoint, .liveAIEnabled])
        XCTAssertEqual(Set(ignored), ["liveAI.enabled", "remoteTranscription.endpoint", "remote.endpoint"])
    }

    func test_nestedKeyWinsOverAFlatOne() {
        let managed = ManagedSettings(source: FakeManagedPreferences(forced: [
            "liveAI": ["model": "nested"] as [String: Any],
            "liveAI.model": "flat",
        ]))
        XCTAssertEqual(managed.liveAIModel, "nested")
    }

    /// `RecordingLanguage.fromCode` reads anything unknown as Hebrew — fine for
    /// legacy recordings, wrong for a lock: a typo would pin everyone to Hebrew.
    func test_recordingLanguage_isValidatedStrictly() {
        XCTAssertEqual(ManagedSettings.strictLanguage("en"), .english)
        XCTAssertEqual(ManagedSettings.strictLanguage("en-US"), .english)
        XCTAssertEqual(ManagedSettings.strictLanguage(" EN "), .english)
        XCTAssertEqual(ManagedSettings.strictLanguage("he_IL"), .hebrew)
        XCTAssertEqual(ManagedSettings.strictLanguage("iw"), .hebrew)
        XCTAssertNil(ManagedSettings.strictLanguage("auto"))
        XCTAssertNil(ManagedSettings.strictLanguage("enochian"))
        XCTAssertNil(ManagedSettings.strictLanguage("eng"))
        XCTAssertNil(ManagedSettings.strictLanguage(""))

        let (managed, ignored) = ManagedSettings.parse(FakeManagedPreferences(forced: [
            "recordingLanguage": "englsh",
        ]))
        XCTAssertNil(managed.recordingLanguage, "An unknown language must not be guessed")
        XCTAssertTrue(managed.isManaged(.recordingLanguage), "…but the field stays locked")
        XCTAssertEqual(ignored, ["recordingLanguage"])
    }

    /// Drift tripwire: the MDM payload IS the `.milaconfig` schema (#360), and
    /// `ManagedField` is the single list every managed code path iterates.
    /// Mirror lists stored properties even when they're nil, so a field added to
    /// `MilaConfig` fails this whether or not anyone populated it below.
    func test_everyMilaconfigField_isManageable() {
        func fields(_ value: Any) -> [String] { Mirror(reflecting: value).children.compactMap(\.label) }

        var expected: [String] = []
        for top in fields(MilaConfig(version: 1)) where top != "version" {
            switch top {
            case "remoteTranscription":
                expected += fields(MilaConfig.RemoteTranscription()).map { "\(top).\($0)" }
            case "liveAI":
                expected += fields(MilaConfig.LiveAI()).map { "\(top).\($0)" }
            case "diarization", "meetingDetection":
                expected += fields(MilaConfig.Toggle()).map { "\(top).\($0)" }
            case "recordingLanguage":
                expected.append(top)
            default:
                XCTFail("New .milaconfig section `\(top)` — add ManagedField cases for it and document it in docs/mdm.md")
            }
        }

        XCTAssertEqual(Set(ManagedField.allCases.map(\.rawValue)), Set(expected),
                       "ManagedField must list exactly the .milaconfig fields, by their paths")
        XCTAssertEqual(fields(ManagedSettings.empty).filter { $0 != "lockedWithoutValue" }.count,
                       ManagedField.allCases.count,
                       "ManagedSettings needs one stored value field per ManagedField")

        let everything = MilaConfig(
            version: 1,
            remoteTranscription: .init(enabled: true, endpoint: "e", model: "m",
                                       englishModel: "en", apiKey: "k"),
            recordingLanguage: "en",
            liveAI: .init(enabled: true, model: "l"),
            diarization: .init(enabled: true),
            meetingDetection: .init(enabled: true))
        XCTAssertEqual(ManagedSettings(config: everything).managedFields, ManagedField.allCases)

        for field in ManagedField.allCases {
            XCTAssertTrue(field.isPresent(in: everything), "\(field)")
            var stripped = everything
            field.remove(from: &stripped)
            XCTAssertEqual(ManagedField.allCases.filter { $0.isPresent(in: stripped) },
                           ManagedField.allCases.filter { $0 != field },
                           "remove(from:) must clear exactly \(field)")
        }
    }
}

// MARK: - Managed fields are forced and never persisted

@MainActor
final class ManagedSettingsEnforcementTests: XCTestCase {

    private func freshDefaults(_ label: String) -> UserDefaults {
        let suite = "ManagedSettingsTests.\(label)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    /// One setting, reached through the object that owns it.
    private struct Probe {
        let object: AnyObject
        let objectWillChange: AnyPublisher<Void, Never>
        let read: () -> String
        /// Writes a value different from the current one.
        let write: () -> Void
    }

    /// `ManagedSettings` with only `field` locked.
    private func managedOnly(_ field: ManagedField) -> ManagedSettings {
        var m = ManagedSettings.empty
        switch field {
        case .backend: m.backend = .remote
        case .endpoint: m.endpoint = "https://org.example.com/v1"
        case .model: m.model = "org-model"
        case .englishModel: m.englishModel = "org-english"
        case .apiKey: m.apiKey = "org-token"
        case .recordingLanguage: m.recordingLanguage = .english
        case .liveAIEnabled: m.liveAIEnabled = false
        case .liveAIModel: m.liveAIModel = "org-live"
        // `true`, so the refused write is to `false` — no diarization side
        // effects (dependency checks, bootstrap) can start in either leg.
        case .diarizationEnabled: m.diarizationEnabled = true
        case .meetingDetectionEnabled: m.meetingDetectionEnabled = false
        }
        return m
    }

    /// Exhaustive on purpose: a new `ManagedField` doesn't compile here until
    /// its owning object and setter are wired into the enforcement check.
    private func probe(_ field: ManagedField, managed: ManagedSettings,
                       defaults: UserDefaults, keychainKey: String) -> Probe {
        @MainActor func publisher<O: ObservableObject>(_ o: O) -> AnyPublisher<Void, Never>
        where O.ObjectWillChangePublisher == ObservableObjectPublisher {
            o.objectWillChange.map { _ in () }.eraseToAnyPublisher()
        }
        @MainActor func remote() -> RemoteTranscriptionSettings {
            RemoteTranscriptionSettings(defaults: defaults, apiKeyKeychainKey: keychainKey, managed: managed)
        }
        switch field {
        case .backend:
            let o = remote()
            return Probe(object: o, objectWillChange: publisher(o), read: { o.backend.rawValue },
                         write: { o.backend = o.backend == .remote ? .local : .remote })
        case .endpoint:
            let o = remote()
            return Probe(object: o, objectWillChange: publisher(o), read: { o.endpoint },
                         write: { o.endpoint += "/changed" })
        case .model:
            let o = remote()
            return Probe(object: o, objectWillChange: publisher(o), read: { o.model },
                         write: { o.model += "-changed" })
        case .englishModel:
            let o = remote()
            return Probe(object: o, objectWillChange: publisher(o), read: { o.englishModel },
                         write: { o.englishModel += "-changed" })
        case .apiKey:
            let o = remote()
            return Probe(object: o, objectWillChange: publisher(o), read: { o.apiKey },
                         write: { o.apiKey += "-changed" })
        case .recordingLanguage:
            let o = RecordingLanguageSettings(defaults: defaults, managed: managed)
            return Probe(object: o, objectWillChange: publisher(o), read: { o.current.rawValue },
                         write: { o.current = o.current.other })
        case .liveAIEnabled:
            let o = LiveAISettings(defaults: defaults, managed: managed)
            return Probe(object: o, objectWillChange: publisher(o), read: { "\(o.enabled)" },
                         write: { o.enabled.toggle() })
        case .liveAIModel:
            let o = LiveAISettings(defaults: defaults, managed: managed)
            return Probe(object: o, objectWillChange: publisher(o), read: { o.model },
                         write: { o.model += "-changed" })
        case .diarizationEnabled:
            let o = DiarizationSettings(defaults: defaults, managed: managed)
            return Probe(object: o, objectWillChange: publisher(o), read: { "\(o.isEnabled)" },
                         write: { o.isEnabled.toggle() })
        case .meetingDetectionEnabled:
            let o = MeetingDetectionSettings(defaults: defaults, managed: managed)
            return Probe(object: o, objectWillChange: publisher(o), read: { "\(o.enabled)" },
                         write: { o.enabled.toggle() })
        }
    }

    private func stored(_ field: ManagedField, _ defaults: UserDefaults, keychainKey: String) -> String {
        if let key = field.storageKey { return String(describing: defaults.object(forKey: key)) }
        return String(describing: KeychainHelper.load(key: keychainKey))
    }

    /// The tripwire for enforcement (not just parsing): for EVERY field, a
    /// write while managed changes nothing — not the value, not the stored
    /// preference, and no `objectWillChange` — while the same write unmanaged
    /// does change and persist it, which also proves `ManagedField.storageKey`
    /// names the key the object really writes.
    func test_everyManagedField_refusesWritesAndPersistsNothing() {
        for field in ManagedField.allCases {
            let keychainKey = "ManagedSettingsTests.enforcement.\(field.rawValue).apiKey"
            KeychainHelper.delete(key: keychainKey)
            defer { KeychainHelper.delete(key: keychainKey) }

            // Managed: refused before anything is stored or published.
            do {
                let defaults = freshDefaults("managed.\(field.rawValue)")
                let managed = managedOnly(field)
                XCTAssertEqual(managed.managedFields, [field])
                let p = probe(field, managed: managed, defaults: defaults, keychainKey: keychainKey)
                let before = p.read()
                let storedBefore = stored(field, defaults, keychainKey: keychainKey)
                var publishes = 0
                let sink = p.objectWillChange.sink { _ in publishes += 1 }
                p.write()
                sink.cancel()
                XCTAssertEqual(p.read(), before, "\(field): a managed value must not change")
                XCTAssertEqual(stored(field, defaults, keychainKey: keychainKey), storedBefore,
                               "\(field): a refused write must persist nothing")
                XCTAssertEqual(publishes, 0, "\(field): a refused write must not publish")
            }

            // Unmanaged: the same write lands and persists.
            do {
                let defaults = freshDefaults("unmanaged.\(field.rawValue)")
                if field == .diarizationEnabled {
                    // Start from ON so the write turns it OFF (no side effects).
                    defaults.set(true, forKey: "diarization.enabled")
                }
                let p = probe(field, managed: .empty, defaults: defaults, keychainKey: keychainKey)
                let before = p.read()
                let storedBefore = stored(field, defaults, keychainKey: keychainKey)
                p.write()
                XCTAssertNotEqual(p.read(), before, "\(field): an unmanaged write must land")
                XCTAssertNotEqual(stored(field, defaults, keychainKey: keychainKey), storedBefore,
                                  "\(field): an unmanaged write must persist under its storage key")
            }
        }
    }

    /// A field locked without a usable value keeps the value it had and
    /// refuses writes, like any other managed field.
    func test_lockedWithoutValue_refusesWrites() {
        let defaults = freshDefaults(#function)
        var managed = ManagedSettings.empty
        managed.lockedWithoutValue = [.liveAIEnabled]
        let liveAI = LiveAISettings(defaults: defaults, managed: managed)
        XCTAssertTrue(liveAI.isManaged(.liveAIEnabled))
        XCTAssertTrue(liveAI.enabled, "Keeps the value it already had (the default here)")

        liveAI.enabled = false
        XCTAssertTrue(liveAI.enabled)
        XCTAssertNil(defaults.object(forKey: "liveAI.enabled"))
    }

    // MARK: Remote transcription specifics

    func test_remote_managedValuesWinOverStoredOnes_andUserValuesSurviveUnderneath() {
        let defaults = freshDefaults(#function)
        let keychainKey = "ManagedSettingsTests.\(#function).apiKey"
        KeychainHelper.delete(key: keychainKey)
        defer { KeychainHelper.delete(key: keychainKey) }

        // The user's own configuration, from before the profile arrived.
        do {
            let user = RemoteTranscriptionSettings(defaults: defaults, apiKeyKeychainKey: keychainKey)
            user.endpoint = "https://user.example.com/v1"
            user.model = "user-model"
        }

        var managed = ManagedSettings.empty
        managed.backend = .remote
        managed.endpoint = "https://org.example.com/v1"
        let remote = RemoteTranscriptionSettings(defaults: defaults,
                                                 apiKeyKeychainKey: keychainKey,
                                                 managed: managed)
        XCTAssertEqual(remote.backend, .remote)
        XCTAssertEqual(remote.endpoint, "https://org.example.com/v1")
        XCTAssertEqual(remote.model, "user-model", "An unmanaged field keeps the user's value")

        // Removing the profile restores what the user had: nothing managed was
        // ever written over it.
        let afterProfileRemoved = RemoteTranscriptionSettings(defaults: defaults, apiKeyKeychainKey: keychainKey)
        XCTAssertEqual(afterProfileRemoved.endpoint, "https://user.example.com/v1")
        XCTAssertEqual(afterProfileRemoved.backend, .local)
    }

    func test_remote_managedAPIKey_bypassesTheKeychainBothWays() {
        let keychainKey = "ManagedSettingsTests.\(#function).apiKey"
        KeychainHelper.save(key: keychainKey, value: "user-token")
        defer { KeychainHelper.delete(key: keychainKey) }

        var managed = ManagedSettings.empty
        managed.backend = .remote
        managed.apiKey = "org-token"
        let remote = RemoteTranscriptionSettings(defaults: freshDefaults(#function),
                                                 apiKeyKeychainKey: keychainKey,
                                                 managed: managed)
        XCTAssertEqual(remote.apiKey, "org-token", "The managed token wins over the stored one")

        remote.apiKey = "typed-over"
        XCTAssertEqual(remote.apiKey, "org-token")
        XCTAssertEqual(KeychainHelper.load(key: keychainKey), "user-token",
                       "A managed token is never written to the Keychain")
    }

    /// Bugbot on #369: an API key forced with an unusable value must keep the
    /// user's own token (loaded from the Keychain as usual) and only refuse
    /// edits — not blank the token and leave remote auth empty.
    func test_remote_apiKeyLockedWithoutValue_stillLoadsTheKeychainToken() {
        let keychainKey = "ManagedSettingsTests.\(#function).apiKey"
        KeychainHelper.save(key: keychainKey, value: "user-token")
        defer { KeychainHelper.delete(key: keychainKey) }

        var managed = ManagedSettings.empty
        managed.backend = .remote
        managed.lockedWithoutValue = [.apiKey]
        let remote = RemoteTranscriptionSettings(defaults: freshDefaults(#function),
                                                 apiKeyKeychainKey: keychainKey,
                                                 managed: managed)
        XCTAssertTrue(remote.isManaged(.apiKey))
        XCTAssertEqual(remote.apiKey, "user-token", "The user's stored token is kept")

        remote.apiKey = "typed-over"
        XCTAssertEqual(remote.apiKey, "user-token", "Edits are still refused")
        XCTAssertEqual(KeychainHelper.load(key: keychainKey), "user-token")
    }

    func test_remote_apiKeyLockedWithoutValue_loadsLazilyOnSwitchToRemote() {
        let keychainKey = "ManagedSettingsTests.\(#function).apiKey"
        KeychainHelper.save(key: keychainKey, value: "user-token")
        defer { KeychainHelper.delete(key: keychainKey) }

        var managed = ManagedSettings.empty
        managed.lockedWithoutValue = [.apiKey]
        let remote = RemoteTranscriptionSettings(defaults: freshDefaults(#function),
                                                 apiKeyKeychainKey: keychainKey,
                                                 managed: managed)
        XCTAssertEqual(remote.apiKey, "", "Still lazy: no Keychain read while local")
        remote.backend = .remote
        XCTAssertEqual(remote.apiKey, "user-token")
    }

    func test_remote_managedEnglishModel_isNotReconciledAway() {
        var managed = ManagedSettings.empty
        managed.model = "ivrit-ai/whisper-large-v3-turbo-ct2"
        managed.englishModel = ""   // the admin says: one model for everything
        let remote = RemoteTranscriptionSettings(defaults: freshDefaults(#function),
                                                 apiKeyKeychainKey: "ManagedSettingsTests.\(#function).apiKey",
                                                 managed: managed)
        XCTAssertEqual(remote.englishModel, "",
                       "The ivrit prefill must not override an administrator's English model")
    }

    // MARK: Presets

    func test_preset_isRefused_whenTheModelIsManaged() {
        var managed = ManagedSettings.empty
        managed.model = "org-model"
        let remote = RemoteTranscriptionSettings(defaults: freshDefaults(#function),
                                                 apiKeyKeychainKey: "ManagedSettingsTests.\(#function).apiKey",
                                                 managed: managed)
        let endpointBefore = remote.endpoint
        let preset = RemoteModelPreset.all.first { $0.endpoint != endpointBefore } ?? RemoteModelPreset.all[0]

        XCTAssertFalse(remote.apply(preset))
        XCTAssertEqual(remote.model, "org-model")
        XCTAssertEqual(remote.endpoint, endpointBefore,
                       "The endpoint must not move to a preset whose model can't follow")
    }

    func test_preset_isRefused_whenItWouldMoveAManagedEndpoint() {
        // A managed endpoint that is a preset's own (OpenAI's), so a preset on a
        // different server would have to move it.
        var managed = ManagedSettings.empty
        managed.endpoint = RemoteTranscriptionSettings.defaultEndpoint
        let remote = RemoteTranscriptionSettings(defaults: freshDefaults(#function),
                                                 apiKeyKeychainKey: "ManagedSettingsTests.\(#function).apiKey",
                                                 managed: managed)
        guard let elsewhere = RemoteModelPreset.all.first(where: {
            RemoteModelPreset.normalizeEndpoint($0.endpoint)
                != RemoteModelPreset.normalizeEndpoint(RemoteTranscriptionSettings.defaultEndpoint)
        }) else { return XCTFail("Expected a preset on another endpoint") }
        let modelBefore = remote.model

        XCTAssertFalse(remote.apply(elsewhere))
        XCTAssertEqual(remote.endpoint, RemoteTranscriptionSettings.defaultEndpoint)
        XCTAssertEqual(remote.model, modelBefore, "No half-applied preset: the model stays too")
    }

    /// `canApply` is what the Settings picker uses to disable presets, so it
    /// must agree with what `apply` actually does for every preset.
    func test_canApply_matchesApply_forEveryPreset() {
        let scenarios: [(String, ManagedSettings)] = [
            ("nothing", .empty),
            ("model", { var m = ManagedSettings.empty; m.model = "org-model"; return m }()),
            ("presetEndpoint", { var m = ManagedSettings.empty
                                 m.endpoint = RemoteTranscriptionSettings.defaultEndpoint; return m }()),
            ("customEndpoint", { var m = ManagedSettings.empty
                                 m.endpoint = "https://org.example.com/v1"; return m }()),
        ]
        for (name, managed) in scenarios {
            for preset in RemoteModelPreset.all {
                let label = "canApply.\(name).\(preset.id)"
                let remote = RemoteTranscriptionSettings(defaults: freshDefaults(label),
                                                         apiKeyKeychainKey: "ManagedSettingsTests.\(label).apiKey",
                                                         managed: managed)
                let predicted = remote.canApply(preset)
                XCTAssertEqual(remote.apply(preset), predicted, "\(name) / \(preset.id)")
            }
        }

        // Only-endpoint-managed on a preset server: presets on that server stay
        // available, presets elsewhere are not offered.
        var managed = ManagedSettings.empty
        managed.endpoint = RemoteTranscriptionSettings.defaultEndpoint
        let remote = RemoteTranscriptionSettings(defaults: freshDefaults("canApply.split"),
                                                 apiKeyKeychainKey: "ManagedSettingsTests.canApply.split.apiKey",
                                                 managed: managed)
        let home = RemoteModelPreset.normalizeEndpoint(RemoteTranscriptionSettings.defaultEndpoint)
        for preset in RemoteModelPreset.all {
            XCTAssertEqual(remote.canApply(preset),
                           RemoteModelPreset.normalizeEndpoint(preset.endpoint) == home,
                           preset.id)
        }
    }

    func test_preset_appliesTheModel_whenAManagedCustomEndpointWouldNotMove() {
        // A non-preset endpoint is never moved by a preset (it may be a gateway
        // serving any id), so only the model changes — no mismatch to refuse.
        var managed = ManagedSettings.empty
        managed.endpoint = "https://org.example.com/v1"
        let remote = RemoteTranscriptionSettings(defaults: freshDefaults(#function),
                                                 apiKeyKeychainKey: "ManagedSettingsTests.\(#function).apiKey",
                                                 managed: managed)
        let preset = RemoteModelPreset.all[0]

        XCTAssertTrue(remote.apply(preset))
        XCTAssertEqual(remote.endpoint, "https://org.example.com/v1")
        XCTAssertEqual(remote.model, preset.id)
    }

    // MARK: Language

    func test_language_forced_userChoiceSurvivesUnderneath() {
        let defaults = freshDefaults(#function)
        defaults.set("he", forKey: "recording.language")
        var managed = ManagedSettings.empty
        managed.recordingLanguage = .english

        let language = RecordingLanguageSettings(defaults: defaults, managed: managed)
        XCTAssertTrue(language.isManaged(.recordingLanguage))
        XCTAssertEqual(language.current, .english)

        language.current = .hebrew
        XCTAssertEqual(language.current, .english)
        XCTAssertEqual(defaults.string(forKey: "recording.language"), "he")
        XCTAssertEqual(RecordingLanguageSettings(defaults: defaults).current, .hebrew,
                       "Without the profile the user's own choice comes back")
    }
}

// MARK: - Precedence over `.milaconfig`

@MainActor
final class ManagedSettingsMilaConfigPrecedenceTests: XCTestCase {

    private struct Harness {
        let importer: MilaConfigImporter
        let remote: RemoteTranscriptionSettings
        let language: RecordingLanguageSettings
        let keychainKey: String
    }

    private func makeHarness(managed: ManagedSettings, _ label: String = #function) -> Harness {
        let suiteName = "ManagedSettingsPrecedenceTests.\(label)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let keychainKey = "ManagedSettingsPrecedenceTests.\(label).apiKey"
        KeychainHelper.delete(key: keychainKey)

        let remote = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: keychainKey,
                                                 managed: managed)
        let language = RecordingLanguageSettings(defaults: suite, managed: managed)
        let importer = MilaConfigImporter(remote: remote,
                                          language: language,
                                          liveAI: LiveAISettings(defaults: suite, managed: managed),
                                          diarization: DiarizationSettings(defaults: suite, managed: managed),
                                          meetingDetection: MeetingDetectionSettings(defaults: suite,
                                                                                     managed: managed),
                                          managed: managed)
        return Harness(importer: importer, remote: remote, language: language, keychainKey: keychainKey)
    }

    private var orgManaged: ManagedSettings {
        var m = ManagedSettings.empty
        m.backend = .remote
        m.endpoint = "https://org.example.com/v1"
        m.apiKey = "org-token"
        m.recordingLanguage = .hebrew
        return m
    }

    private var teammateConfig: MilaConfig {
        MilaConfig(version: 1,
                   remoteTranscription: .init(enabled: false,
                                              endpoint: "https://elsewhere.example.com/v1",
                                              model: "file-model",
                                              apiKey: "file-token"),
                   recordingLanguage: "en")
    }

    func test_plannedChanges_omitManagedFields_andListThemAsManaged() {
        let h = makeHarness(managed: orgManaged)
        defer { KeychainHelper.delete(key: h.keychainKey) }

        let labels = h.importer.plannedChanges(for: teammateConfig).map(\.label)
        XCTAssertEqual(labels, ["Model"],
                       "Only the unmanaged field that differs is offered as a change")
        XCTAssertEqual(h.importer.managedSkipped(for: teammateConfig),
                       ["Transcription", "Server URL", "API key", "Recording language"])
    }

    func test_apply_leavesManagedFields_andAppliesTheRest() {
        let h = makeHarness(managed: orgManaged)
        defer { KeychainHelper.delete(key: h.keychainKey) }

        h.importer.apply(teammateConfig)

        XCTAssertEqual(h.remote.backend, .remote)
        XCTAssertEqual(h.remote.endpoint, "https://org.example.com/v1")
        XCTAssertEqual(h.remote.apiKey, "org-token")
        XCTAssertNil(KeychainHelper.load(key: h.keychainKey),
                     "The file's token must not reach the Keychain while the key is managed")
        XCTAssertEqual(h.language.current, .hebrew)
        XCTAssertEqual(h.remote.model, "file-model", "Unmanaged fields still import")
    }

    func test_nothingManaged_importBehavesAsBefore() {
        let h = makeHarness(managed: .empty)
        defer { KeychainHelper.delete(key: h.keychainKey) }

        XCTAssertTrue(h.importer.managedSkipped(for: teammateConfig).isEmpty)
        h.importer.apply(teammateConfig)
        XCTAssertEqual(h.remote.endpoint, "https://elsewhere.example.com/v1")
        XCTAssertEqual(h.language.current, .english)
    }
}
