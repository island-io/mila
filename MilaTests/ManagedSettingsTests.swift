import XCTest
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
        XCTAssertTrue(managed.managedFieldNames.isEmpty)
    }

    func test_readsEveryMilaconfigKey_withTheSameNames() {
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
        XCTAssertEqual(managed.managedFieldNames.count, 10)
    }

    func test_partialSection_managesOnlyThePresentFields() {
        let source = FakeManagedPreferences(forced: [
            "remoteTranscription": ["endpoint": "https://asr.example.com/v1"] as [String: Any],
        ])
        let managed = ManagedSettings(source: source)
        XCTAssertEqual(managed.endpoint, "https://asr.example.com/v1")
        XCTAssertNil(managed.backend, "Absent `enabled` must leave the backend to the user")
        XCTAssertNil(managed.model)
        XCTAssertNil(managed.apiKey)
        XCTAssertNil(managed.recordingLanguage)
        XCTAssertEqual(managed.managedFieldNames, ["remoteTranscription.endpoint"])
    }

    func test_enabledFalse_managesTheBackendAsLocal() {
        let managed = ManagedSettings(source: FakeManagedPreferences(forced: [
            "remoteTranscription": ["enabled": false] as [String: Any],
        ]))
        XCTAssertEqual(managed.backend, .local)
    }

    func test_wrongTypes_dropOnlyThatField() {
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
        let managed = ManagedSettings(source: source)
        XCTAssertNil(managed.backend)
        XCTAssertEqual(managed.endpoint, "https://asr.example.com/v1")
        XCTAssertNil(managed.model)
        XCTAssertNil(managed.diarizationEnabled)
        XCTAssertNil(managed.recordingLanguage)
        XCTAssertEqual(managed.meetingDetectionEnabled, true)
    }

    /// Drift tripwire: the MDM payload IS the `.milaconfig` schema (#360), so
    /// a field added to `MilaConfig` must become manageable too. Mirror lists
    /// stored properties even when they're nil, so a new field fails this
    /// whether or not anyone remembered to populate it below.
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
                XCTFail("New .milaconfig section `\(top)` — make it manageable in ManagedSettings and docs/mdm.md")
            }
        }

        XCTAssertEqual(fields(ManagedSettings.empty).count, expected.count,
                       "ManagedSettings needs one field per .milaconfig field")

        let everything = MilaConfig(
            version: 1,
            remoteTranscription: .init(enabled: true, endpoint: "e", model: "m",
                                       englishModel: "en", apiKey: "k"),
            recordingLanguage: "en",
            liveAI: .init(enabled: true, model: "l"),
            diarization: .init(enabled: true),
            meetingDetection: .init(enabled: true))
        XCTAssertEqual(Set(ManagedSettings(config: everything).managedFieldNames), Set(expected))
    }

    func test_languageCode_readTheSameWayAsMilaconfig() {
        // `RecordingLanguage.fromCode`: regional forms count, anything else is
        // Hebrew — identical to a `.milaconfig`'s `recordingLanguage`.
        XCTAssertEqual(ManagedSettings(config: MilaConfig(version: 1, recordingLanguage: "en-US")).recordingLanguage,
                       .english)
        XCTAssertEqual(ManagedSettings(config: MilaConfig(version: 1, recordingLanguage: "auto")).recordingLanguage,
                       .hebrew)
    }
}

// MARK: - Managed fields are forced and never persisted

@MainActor
final class ManagedSettingsEnforcementTests: XCTestCase {

    private func freshDefaults(_ label: String = #function) -> UserDefaults {
        let suite = "ManagedSettingsTests.\(label)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    // MARK: Remote transcription

    func test_remote_managedValuesWinOverStoredOnes_andUserValuesSurviveUnderneath() {
        let defaults = freshDefaults()
        let keychainKey = "ManagedSettingsTests.\(#function).apiKey"
        KeychainHelper.delete(key: keychainKey)
        defer { KeychainHelper.delete(key: keychainKey) }

        // The user's own configuration, from before the profile arrived.
        do {
            let user = RemoteTranscriptionSettings(defaults: defaults, apiKeyKeychainKey: keychainKey)
            user.endpoint = "https://user.example.com/v1"
            user.model = "whisper-1"
        }

        var managed = ManagedSettings.empty
        managed.backend = .remote
        managed.endpoint = "https://org.example.com/v1"
        let remote = RemoteTranscriptionSettings(defaults: defaults,
                                                 apiKeyKeychainKey: keychainKey,
                                                 managed: managed)
        XCTAssertEqual(remote.backend, .remote)
        XCTAssertEqual(remote.endpoint, "https://org.example.com/v1")
        XCTAssertEqual(remote.model, "whisper-1", "An unmanaged field keeps the user's value")

        // Removing the profile restores what the user had: nothing managed was
        // ever written over it.
        let afterProfileRemoved = RemoteTranscriptionSettings(defaults: defaults, apiKeyKeychainKey: keychainKey)
        XCTAssertEqual(afterProfileRemoved.endpoint, "https://user.example.com/v1")
        XCTAssertEqual(afterProfileRemoved.backend, .local)
    }

    func test_remote_writesToManagedFieldsAreRefused_andNotPersisted() {
        let defaults = freshDefaults()
        let keychainKey = "ManagedSettingsTests.\(#function).apiKey"
        KeychainHelper.delete(key: keychainKey)
        defer { KeychainHelper.delete(key: keychainKey) }

        var managed = ManagedSettings.empty
        managed.backend = .remote
        managed.endpoint = "https://org.example.com/v1"
        managed.model = "org-model"
        let remote = RemoteTranscriptionSettings(defaults: defaults,
                                                 apiKeyKeychainKey: keychainKey,
                                                 managed: managed)

        remote.backend = .local
        remote.endpoint = "https://elsewhere.example.com/v1"
        remote.model = "other-model"
        remote.englishModel = "user-english"   // not managed: allowed

        XCTAssertEqual(remote.backend, .remote)
        XCTAssertEqual(remote.endpoint, "https://org.example.com/v1")
        XCTAssertEqual(remote.model, "org-model")
        XCTAssertEqual(remote.englishModel, "user-english")
        XCTAssertNil(defaults.string(forKey: "transcription.backend"), "A managed backend is never persisted")
        XCTAssertNil(defaults.string(forKey: "remote.endpoint"), "A managed endpoint is never persisted")
        XCTAssertNil(defaults.string(forKey: "remote.model"), "A managed model is never persisted")
        XCTAssertEqual(defaults.string(forKey: "remote.model.en"), "user-english")
    }

    func test_remote_presetKeepsAManagedEndpoint() {
        let defaults = freshDefaults()
        var managed = ManagedSettings.empty
        managed.endpoint = "https://org.example.com/v1"
        let remote = RemoteTranscriptionSettings(defaults: defaults,
                                                 apiKeyKeychainKey: "ManagedSettingsTests.\(#function).apiKey",
                                                 managed: managed)
        guard let preset = RemoteModelPreset.all.first(where: {
            RemoteModelPreset.normalizeEndpoint($0.endpoint)
                != RemoteModelPreset.normalizeEndpoint(managed.endpoint!)
        }) else { return XCTFail("Expected a preset with a different endpoint") }

        remote.apply(preset)
        XCTAssertEqual(remote.endpoint, "https://org.example.com/v1")
        XCTAssertEqual(remote.model, preset.id, "The unmanaged model still follows the preset")
    }

    func test_remote_managedAPIKey_bypassesTheKeychainBothWays() {
        let defaults = freshDefaults()
        let keychainKey = "ManagedSettingsTests.\(#function).apiKey"
        KeychainHelper.save(key: keychainKey, value: "user-token")
        defer { KeychainHelper.delete(key: keychainKey) }

        var managed = ManagedSettings.empty
        managed.backend = .remote
        managed.apiKey = "org-token"
        let remote = RemoteTranscriptionSettings(defaults: defaults,
                                                 apiKeyKeychainKey: keychainKey,
                                                 managed: managed)
        XCTAssertEqual(remote.apiKey, "org-token", "The managed token wins over the stored one")

        remote.apiKey = "typed-over"
        XCTAssertEqual(remote.apiKey, "org-token")
        XCTAssertEqual(KeychainHelper.load(key: keychainKey), "user-token",
                       "A managed token is never written to the Keychain")
    }

    func test_remote_managedEnglishModel_isNotReconciledAway() {
        var managed = ManagedSettings.empty
        managed.model = "ivrit-ai/whisper-large-v3-turbo-ct2"
        managed.englishModel = ""   // the admin says: one model for everything
        let remote = RemoteTranscriptionSettings(defaults: freshDefaults(),
                                                 apiKeyKeychainKey: "ManagedSettingsTests.\(#function).apiKey",
                                                 managed: managed)
        XCTAssertEqual(remote.englishModel, "",
                       "The ivrit prefill must not override an administrator's English model")
    }

    // MARK: Language, Live AI, diarization, meeting detection

    func test_language_forced_andNotPersisted() {
        let defaults = freshDefaults()
        defaults.set("he", forKey: "recording.language")
        var managed = ManagedSettings.empty
        managed.recordingLanguage = .english

        let language = RecordingLanguageSettings(defaults: defaults, managed: managed)
        XCTAssertTrue(language.isManaged)
        XCTAssertEqual(language.current, .english)

        language.current = .hebrew
        XCTAssertEqual(language.current, .english)
        XCTAssertEqual(defaults.string(forKey: "recording.language"), "he",
                       "The user's own choice is left untouched underneath")
    }

    func test_liveAI_forced_andNotPersisted() {
        let defaults = freshDefaults()
        var managed = ManagedSettings.empty
        managed.liveAIEnabled = false
        managed.liveAIModel = "org-model"

        let liveAI = LiveAISettings(defaults: defaults, managed: managed)
        XCTAssertFalse(liveAI.enabled)
        XCTAssertEqual(liveAI.model, "org-model")

        liveAI.enabled = true
        liveAI.model = "user-model"
        XCTAssertFalse(liveAI.enabled)
        XCTAssertEqual(liveAI.model, "org-model")
        XCTAssertNil(defaults.object(forKey: "liveAI.enabled"))
        XCTAssertNil(defaults.object(forKey: "liveAI.model"))
    }

    func test_diarization_forced_andNotPersisted() {
        let defaults = freshDefaults()
        var managed = ManagedSettings.empty
        managed.diarizationEnabled = false

        let diarization = DiarizationSettings(defaults: defaults, managed: managed)
        XCTAssertTrue(diarization.isEnabledManaged)
        XCTAssertFalse(diarization.isEnabled)

        diarization.isEnabled = true
        XCTAssertFalse(diarization.isEnabled)
        XCTAssertNil(defaults.object(forKey: "diarization.enabled"))
    }

    func test_meetingDetection_forced_andNotPersisted() {
        let defaults = freshDefaults()
        var managed = ManagedSettings.empty
        managed.meetingDetectionEnabled = false

        let meetings = MeetingDetectionSettings(defaults: defaults, managed: managed)
        XCTAssertTrue(meetings.isEnabledManaged)
        XCTAssertFalse(meetings.enabled)

        meetings.enabled = true
        XCTAssertFalse(meetings.enabled)
        // init seeds the user's own default (ON); the managed OFF never lands there.
        XCTAssertEqual(defaults.object(forKey: "meetingDetection.enabled") as? Bool, true)
    }

    func test_unmanagedObjects_behaveAsBefore() {
        let defaults = freshDefaults()
        let meetings = MeetingDetectionSettings(defaults: defaults)
        XCTAssertFalse(meetings.isEnabledManaged)
        meetings.enabled = false
        XCTAssertFalse(meetings.enabled)
        XCTAssertEqual(defaults.object(forKey: "meetingDetection.enabled") as? Bool, false)
    }
}

// MARK: - Precedence over `.milaconfig`

@MainActor
final class ManagedSettingsMilaConfigPrecedenceTests: XCTestCase {

    private struct Harness {
        let importer: MilaConfigImporter
        let remote: RemoteTranscriptionSettings
        let language: RecordingLanguageSettings
        let diarization: DiarizationSettings
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
        let diarization = DiarizationSettings(defaults: suite, managed: managed)
        let importer = MilaConfigImporter(remote: remote,
                                          language: language,
                                          liveAI: LiveAISettings(defaults: suite, managed: managed),
                                          diarization: diarization,
                                          meetingDetection: MeetingDetectionSettings(defaults: suite,
                                                                                     managed: managed))
        return Harness(importer: importer, remote: remote, language: language,
                       diarization: diarization, keychainKey: keychainKey)
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
        XCTAssertEqual(Set(labels), ["Model"],
                       "Only the unmanaged field that differs is offered as a change")

        XCTAssertEqual(Set(h.importer.managedSkipped(for: teammateConfig)),
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
