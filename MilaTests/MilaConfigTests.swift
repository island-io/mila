import XCTest
@testable import Mila

// MARK: - Parsing / versioning

final class MilaConfigDecodeTests: XCTestCase {

    func test_decode_parsesAllFields() throws {
        let json = """
        {
          "version": 1,
          "remoteTranscription": {
            "enabled": true,
            "endpoint": "https://mila-asr.internal.island.io/v1",
            "model": "ivrit-ai/whisper-large-v3-turbo-ct2",
            "apiKey": "secret-123"
          },
          "recordingLanguage": "he",
          "liveAI": { "enabled": false, "model": "claude" },
          "diarization": { "enabled": true },
          "meetingDetection": { "enabled": false }
        }
        """.data(using: .utf8)!

        let config = try MilaConfig.decode(json)
        XCTAssertEqual(config.version, 1)
        XCTAssertEqual(config.remoteTranscription?.enabled, true)
        XCTAssertEqual(config.remoteTranscription?.endpoint, "https://mila-asr.internal.island.io/v1")
        XCTAssertEqual(config.remoteTranscription?.model, "ivrit-ai/whisper-large-v3-turbo-ct2")
        XCTAssertEqual(config.remoteTranscription?.apiKey, "secret-123")
        XCTAssertEqual(config.recordingLanguage, "he")
        XCTAssertEqual(config.liveAI?.enabled, false)
        XCTAssertEqual(config.liveAI?.model, "claude")
        XCTAssertEqual(config.diarization?.enabled, true)
        XCTAssertEqual(config.meetingDetection?.enabled, false)
    }

    func test_decode_absentFieldsAreNil() throws {
        // Only the server URL is present; everything else must decode to nil so
        // the applier leaves those settings untouched.
        let json = """
        { "version": 1, "remoteTranscription": { "endpoint": "https://x/v1" } }
        """.data(using: .utf8)!

        let config = try MilaConfig.decode(json)
        XCTAssertEqual(config.remoteTranscription?.endpoint, "https://x/v1")
        XCTAssertNil(config.remoteTranscription?.enabled)
        XCTAssertNil(config.remoteTranscription?.model)
        XCTAssertNil(config.remoteTranscription?.apiKey)
        XCTAssertNil(config.recordingLanguage)
        XCTAssertNil(config.liveAI)
        XCTAssertNil(config.diarization)
        XCTAssertNil(config.meetingDetection)
    }

    func test_decode_missingVersion_throwsMalformed() {
        let json = """
        { "recordingLanguage": "he" }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try MilaConfig.decode(json)) { error in
            guard case MilaConfig.LoadError.malformed = error else {
                return XCTFail("Expected .malformed, got \(error)")
            }
        }
    }

    func test_decode_futureVersion_throwsUnsupported() {
        let json = """
        { "version": 999 }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try MilaConfig.decode(json)) { error in
            guard case MilaConfig.LoadError.unsupportedVersion(let found, let supported) = error else {
                return XCTFail("Expected .unsupportedVersion, got \(error)")
            }
            XCTAssertEqual(found, 999)
            XCTAssertEqual(supported, MilaConfig.currentVersion)
        }
    }

    func test_decode_garbage_throwsMalformed() {
        let json = "not json at all".data(using: .utf8)!
        XCTAssertThrowsError(try MilaConfig.decode(json)) { error in
            guard case MilaConfig.LoadError.malformed = error else {
                return XCTFail("Expected .malformed, got \(error)")
            }
        }
    }
}

// MARK: - Apply / diff

@MainActor
final class MilaConfigImporterTests: XCTestCase {

    private struct Harness {
        let importer: MilaConfigImporter
        let remote: RemoteTranscriptionSettings
        let language: RecordingLanguageSettings
        let liveAI: LiveAISettings
        let diarization: DiarizationSettings
        let meetingDetection: MeetingDetectionSettings
        let keychainKey: String
    }

    private func makeHarness(_ label: String = #function) -> Harness {
        let suiteName = "MilaConfigTests.\(label)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        let keychainKey = "MilaConfigTests.\(label).apiKey"
        KeychainHelper.delete(key: keychainKey)

        let remote = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: keychainKey)
        let language = RecordingLanguageSettings(defaults: suite)
        let liveAI = LiveAISettings(defaults: suite)
        let diarization = DiarizationSettings(defaults: suite)
        let meetingDetection = MeetingDetectionSettings(defaults: suite)
        let importer = MilaConfigImporter(remote: remote,
                                          language: language,
                                          liveAI: liveAI,
                                          diarization: diarization,
                                          meetingDetection: meetingDetection)
        return Harness(importer: importer, remote: remote, language: language,
                       liveAI: liveAI, diarization: diarization,
                       meetingDetection: meetingDetection, keychainKey: keychainKey)
    }

    func test_apply_fullRemote_setsBackendEndpointModelKey() {
        let h = makeHarness()
        defer { KeychainHelper.delete(key: h.keychainKey) }
        XCTAssertEqual(h.remote.backend, .local)

        h.importer.apply(MilaConfig(
            version: 1,
            remoteTranscription: .init(enabled: true,
                                       endpoint: "https://mila-asr.internal.island.io/v1",
                                       model: "ivrit-ai/whisper-large-v3-turbo-ct2",
                                       apiKey: "secret-123")
        ))

        XCTAssertEqual(h.remote.backend, .remote)
        XCTAssertEqual(h.remote.endpoint, "https://mila-asr.internal.island.io/v1")
        XCTAssertEqual(h.remote.model, "ivrit-ai/whisper-large-v3-turbo-ct2")
        XCTAssertEqual(h.remote.apiKey, "secret-123",
                       "Key set from config must survive the backend switch's lazy Keychain load")
        XCTAssertTrue(h.remote.isConfigured)
    }

    func test_apply_absentFieldsLeaveCurrentUntouched() {
        let h = makeHarness()
        defer { KeychainHelper.delete(key: h.keychainKey) }
        // Seed a current state.
        h.remote.model = "current-model"
        h.language.current = .english

        // A config that only changes the endpoint.
        h.importer.apply(MilaConfig(
            version: 1,
            remoteTranscription: .init(endpoint: "https://only-endpoint/v1")
        ))

        XCTAssertEqual(h.remote.endpoint, "https://only-endpoint/v1")
        XCTAssertEqual(h.remote.model, "current-model", "Absent model must not be overridden")
        XCTAssertEqual(h.remote.backend, .local, "Absent enabled must not switch the backend")
        XCTAssertEqual(h.language.current, .english, "Absent language must not be overridden")
    }

    func test_apply_enabledFalse_revertsToLocal() {
        let h = makeHarness()
        defer { KeychainHelper.delete(key: h.keychainKey) }
        h.remote.backend = .remote
        XCTAssertEqual(h.remote.backend, .remote)

        h.importer.apply(MilaConfig(version: 1, remoteTranscription: .init(enabled: false)))
        XCTAssertEqual(h.remote.backend, .local)
    }

    func test_apply_setsLanguageAndToggles() {
        let h = makeHarness()
        defer { KeychainHelper.delete(key: h.keychainKey) }
        h.importer.apply(MilaConfig(
            version: 1,
            recordingLanguage: "en",
            liveAI: .init(enabled: true, model: "claude"),
            diarization: .init(enabled: true),
            meetingDetection: .init(enabled: false)
        ))
        XCTAssertEqual(h.language.current, .english)
        XCTAssertTrue(h.liveAI.enabled)
        XCTAssertEqual(h.liveAI.model, "claude")
        XCTAssertTrue(h.diarization.isEnabled)
        XCTAssertFalse(h.meetingDetection.enabled)
    }

    func test_plannedChanges_listsOnlyDiffs_andMasksKey() {
        let h = makeHarness()
        defer { KeychainHelper.delete(key: h.keychainKey) }
        // model matches the current default → should NOT appear as a change.
        let config = MilaConfig(
            version: 1,
            remoteTranscription: .init(enabled: true,
                                       endpoint: "https://mila-asr.internal.island.io/v1",
                                       model: RemoteTranscriptionSettings.defaultModel,
                                       apiKey: "supersecretvalue")
        )
        let changes = h.importer.plannedChanges(for: config)
        let labels = changes.map(\.label)
        XCTAssertTrue(labels.contains("Transcription"))
        XCTAssertTrue(labels.contains("Server URL"))
        XCTAssertTrue(labels.contains("API key"))
        XCTAssertFalse(labels.contains("Model"), "A value equal to current must not be listed")

        let keyChange = changes.first { $0.label == "API key" }
        XCTAssertNotNil(keyChange)
        XCTAssertFalse(keyChange!.value.contains("supersecret"), "Key must be masked")
        XCTAssertTrue(keyChange!.value.hasSuffix("alue"), "Last 4 chars are shown")
    }

    func test_plannedChanges_emptyWhenConfigMatchesCurrent() {
        let h = makeHarness()
        defer { KeychainHelper.delete(key: h.keychainKey) }
        // Current: backend .local + whatever language a fresh install
        // defaults to. Reference the live value rather than hardcoding it
        // so this test tracks the fresh-install default (English as of the
        // Russian-language PR; Hebrew before that) instead of breaking
        // every time the default changes.
        let config = MilaConfig(
            version: 1,
            remoteTranscription: .init(enabled: false),
            recordingLanguage: h.language.current.rawValue
        )
        XCTAssertTrue(h.importer.plannedChanges(for: config).isEmpty)
    }

    func test_handleOpen_stagesPending_thenConfirmApplies() throws {
        let h = makeHarness()
        defer { KeychainHelper.delete(key: h.keychainKey) }

        let json = """
        {
          "version": 1,
          "remoteTranscription": {
            "enabled": true,
            "endpoint": "https://mila-asr.internal.island.io/v1",
            "model": "ivrit-ai/whisper-large-v3-turbo-ct2",
            "apiKey": "secret-123"
          }
        }
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-test-\(UUID().uuidString).milaconfig")
        try json.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        h.importer.handleOpen(url)
        XCTAssertNil(h.importer.errorMessage)
        XCTAssertNotNil(h.importer.pending)
        XCTAssertFalse(h.importer.pending?.changes.isEmpty ?? true)

        h.importer.confirm()
        XCTAssertNil(h.importer.pending, "Confirm clears the pending state")
        XCTAssertEqual(h.remote.backend, .remote)
        XCTAssertEqual(h.remote.endpoint, "https://mila-asr.internal.island.io/v1")
    }

    func test_handleOpen_malformedFile_setsError() throws {
        let h = makeHarness()
        defer { KeychainHelper.delete(key: h.keychainKey) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mila-bad-\(UUID().uuidString).milaconfig")
        try "{ not valid ".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        h.importer.handleOpen(url)
        XCTAssertNil(h.importer.pending)
        XCTAssertNotNil(h.importer.errorMessage)
    }
}
