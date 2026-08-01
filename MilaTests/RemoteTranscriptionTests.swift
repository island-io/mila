import XCTest
import TranscriptionCore
@testable import Mila

@MainActor
final class RemoteTranscriptionSettingsTests: XCTestCase {

    private func makeSettings(_ label: String = #function) -> RemoteTranscriptionSettings {
        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.\(label)")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.\(label)")
        // Isolated Keychain item so these tests never read/clobber the real
        // app's `remote.apiKey`.
        return RemoteTranscriptionSettings(defaults: suite,
                                           apiKeyKeychainKey: "RemoteTranscriptionSettingsTests.\(label).apiKey")
    }

    func test_defaults_areLocalAndOpenAI() {
        let settings = makeSettings()
        XCTAssertEqual(settings.backend, .local)
        XCTAssertFalse(settings.isActive)
        XCTAssertEqual(settings.endpoint, RemoteTranscriptionSettings.defaultEndpoint)
        XCTAssertEqual(settings.model, RemoteTranscriptionSettings.defaultModel)
    }

    func test_isConfigured_requiresKeyForOpenAI() {
        let settings = makeSettings()
        settings.backend = .remote
        settings.endpoint = "https://api.openai.com/v1"
        settings.apiKey = ""
        XCTAssertFalse(settings.isConfigured, "OpenAI endpoint must require a key")
        settings.apiKey = "sk-test"
        XCTAssertTrue(settings.isConfigured)
    }

    func test_isConfigured_allowsAnonymousSelfHosted() {
        let settings = makeSettings()
        settings.backend = .remote
        settings.endpoint = "http://localhost:8000/v1"
        settings.apiKey = ""
        XCTAssertTrue(settings.isConfigured, "Self-hosted endpoints may be anonymous")
    }

    func test_endpointURL_rejectsGarbage() {
        let settings = makeSettings()
        settings.endpoint = "not a url"
        XCTAssertNil(settings.endpointURL)
        settings.endpoint = "ftp://example.com"
        XCTAssertNil(settings.endpointURL, "Only http(s) is allowed")
        settings.endpoint = "https://example.com/v1"
        XCTAssertNotNil(settings.endpointURL)
    }

    func test_currentConfig_trimsAndFallsBackModel() {
        let settings = makeSettings()
        settings.backend = .remote
        settings.endpoint = "  https://example.com/v1  "
        settings.model = "   "
        let config = settings.currentConfig()
        XCTAssertEqual(config?.endpoint.absoluteString, "https://example.com/v1")
        XCTAssertEqual(config?.model, RemoteTranscriptionSettings.defaultModel)
    }

    // MARK: - Per-language model routing

    func test_modelForLanguage_withoutEnglishModel_alwaysUsesPrimary() {
        let settings = makeSettings()
        // A multilingual primary is the case that stays blank — the prefill is
        // ivrit-only (see `test_prefill_leavesMultilingualEndpointsAlone`), so
        // this exercises the resolver's "empty means use the primary" fallback.
        settings.model = "Systran/faster-whisper-large-v3"
        XCTAssertEqual(settings.englishModel, "", "Precondition: nothing pre-filled here")
        XCTAssertEqual(settings.model(for: "he"), "Systran/faster-whisper-large-v3")
        XCTAssertEqual(settings.model(for: "en"), "Systran/faster-whisper-large-v3")
        XCTAssertEqual(settings.model(for: "auto"), "Systran/faster-whisper-large-v3",
                       "Legacy auto must not resolve to a model the user never configured")
    }

    /// The same fallback with an ivrit primary, which only stays blank once the
    /// user has cleared the field by hand. Their clear must route every language
    /// back to the primary rather than resurrecting the pre-filled English id.
    func test_modelForLanguage_ivritPrimaryWithClearedEnglishModel_usesPrimary() {
        let settings = makeUpgrading(from: "ivrit-ai/whisper-large-v3-turbo-ct2", cleared: true)
        XCTAssertEqual(settings.englishModel, "")
        XCTAssertEqual(settings.model(for: "he"), "ivrit-ai/whisper-large-v3-turbo-ct2")
        XCTAssertEqual(settings.model(for: "en"), "ivrit-ai/whisper-large-v3-turbo-ct2")
        XCTAssertEqual(settings.model(for: "auto"), "ivrit-ai/whisper-large-v3-turbo-ct2")
    }

    func test_modelForLanguage_routesEnglishAndAutoToEnglishModel() {
        let settings = makeSettings()
        settings.model = "ivrit-ai/whisper-large-v3-turbo-ct2"
        settings.englishModel = "deepdml/faster-whisper-large-v3-turbo-ct2"
        XCTAssertEqual(settings.model(for: "he"), "ivrit-ai/whisper-large-v3-turbo-ct2")
        XCTAssertEqual(settings.model(for: "iw"), "ivrit-ai/whisper-large-v3-turbo-ct2",
                       "Legacy Hebrew code must route like `he`")
        XCTAssertEqual(settings.model(for: "en"), "deepdml/faster-whisper-large-v3-turbo-ct2")
        XCTAssertEqual(settings.model(for: "en-US"), "deepdml/faster-whisper-large-v3-turbo-ct2")
        // Auto-detect is retired as a user choice, but recordings made under it
        // keep "auto" on disk and can be re-transcribed. Only the multilingual
        // model can serve a detect-the-language request.
        XCTAssertEqual(settings.model(for: "auto"), "deepdml/faster-whisper-large-v3-turbo-ct2")
    }

    func test_modelForLanguage_trimsWhitespace() {
        let settings = makeSettings()
        settings.model = "  primary  "
        settings.englishModel = "  english  "
        XCTAssertEqual(settings.model(for: "he"), "primary")
        XCTAssertEqual(settings.model(for: "en"), "english")
        // Whitespace-only is indistinguishable from unset.
        settings.englishModel = "   "
        XCTAssertEqual(settings.model(for: "en"), "primary")
    }

    func test_currentConfig_bakesInTheLanguageRoutedModel() {
        let settings = makeSettings()
        settings.backend = .remote
        settings.endpoint = "https://example.com/v1"
        settings.model = "hebrew-model"
        settings.englishModel = "english-model"
        XCTAssertEqual(settings.currentConfig(for: "en")?.model, "english-model")
        XCTAssertEqual(settings.currentConfig(for: "he")?.model, "hebrew-model")
        // No language (the connection probe) → primary.
        XCTAssertEqual(settings.currentConfig()?.model, "hebrew-model")
    }

    func test_englishModel_persistsAcrossInstances() {
        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.\(#function)")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.\(#function)")
        let key = "RemoteTranscriptionSettingsTests.\(#function).apiKey"

        let first = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: key)
        XCTAssertEqual(first.englishModel, "", "Must default to empty (= use primary)")
        first.englishModel = "deepdml/faster-whisper-large-v3-turbo-ct2"

        let second = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: key)
        XCTAssertEqual(second.englishModel, "deepdml/faster-whisper-large-v3-turbo-ct2")
    }

    // MARK: - English-model prefill

    /// Helper: build settings over a suite that already has a persisted primary
    /// model, i.e. an existing user upgrading into per-language routing.
    private func makeUpgrading(from primary: String,
                               englishModel: String? = nil,
                               cleared: Bool = false,
                               _ label: String = #function) -> RemoteTranscriptionSettings {
        let name = "RemoteTranscriptionSettingsTests.prefill.\(label)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        suite.set(primary, forKey: "remote.model")
        if let englishModel { suite.set(englishModel, forKey: "remote.model.en") }
        if cleared { suite.set(true, forKey: "remote.model.en.cleared") }
        return RemoteTranscriptionSettings(defaults: suite,
                                           apiKeyKeychainKey: "\(name).apiKey")
    }

    func test_isHebrewOnlyModel_matchesIvritVariants() {
        XCTAssertTrue(RemoteTranscriptionSettings.isHebrewOnlyModel("ivrit-ai/whisper-large-v3-turbo-ct2"))
        XCTAssertTrue(RemoteTranscriptionSettings.isHebrewOnlyModel("IVRIT-AI/whisper-large-v3-ggml"))
        XCTAssertTrue(RemoteTranscriptionSettings.isHebrewOnlyModel("my-mirror/ivrit-large-v3"))
        XCTAssertFalse(RemoteTranscriptionSettings.isHebrewOnlyModel("whisper-1"))
        XCTAssertFalse(RemoteTranscriptionSettings.isHebrewOnlyModel("Systran/faster-whisper-large-v3"))
        XCTAssertFalse(RemoteTranscriptionSettings.isHebrewOnlyModel(""))
    }

    /// The upgrade case this exists for: an ivrit primary and no English model
    /// means English audio goes to Hebrew-only weights. Fill it in.
    func test_prefill_populatesEnglishModel_forIvritPrimary() {
        let settings = makeUpgrading(from: "ivrit-ai/whisper-large-v3-turbo-ct2")
        XCTAssertEqual(settings.englishModel, RemoteTranscriptionSettings.defaultEnglishModel)
        XCTAssertEqual(settings.model(for: "en"), RemoteTranscriptionSettings.defaultEnglishModel)
        XCTAssertEqual(settings.model(for: "he"), "ivrit-ai/whisper-large-v3-turbo-ct2")
    }

    /// A blank English model is CORRECT for a multilingual endpoint — filling one
    /// in would send OpenAI a model id it doesn't have and break English outright.
    func test_prefill_leavesMultilingualEndpointsAlone() {
        XCTAssertEqual(makeUpgrading(from: "whisper-1", "openai").englishModel, "")
        XCTAssertEqual(makeUpgrading(from: "Systran/faster-whisper-large-v3", "systran").englishModel, "")
    }

    func test_prefill_doesNotOverrideAUserChoice() {
        let settings = makeUpgrading(from: "ivrit-ai/whisper-large-v3-turbo-ct2",
                                     englishModel: "my-own/english-model")
        XCTAssertEqual(settings.englishModel, "my-own/english-model")
    }

    /// Clearing the field is a decision. It must survive a relaunch.
    func test_prefill_respectsAnExplicitClear() {
        let name = "RemoteTranscriptionSettingsTests.prefill.\(#function)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        suite.set("ivrit-ai/whisper-large-v3-turbo-ct2", forKey: "remote.model")

        let first = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: "\(name).apiKey")
        XCTAssertEqual(first.englishModel, RemoteTranscriptionSettings.defaultEnglishModel)
        first.englishModel = ""   // user empties it by hand

        let relaunched = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: "\(name).apiKey")
        XCTAssertEqual(relaunched.englishModel, "", "An explicit clear must not be re-filled")
    }

    /// Switching the primary TO an ivrit model is the other moment the English
    /// model becomes necessary — e.g. applying a `.milaconfig` from a teammate.
    func test_prefill_firesWhenPrimaryChangesToIvrit() {
        let settings = makeSettings()
        XCTAssertEqual(settings.englishModel, "")
        settings.model = "ivrit-ai/whisper-large-v3-turbo-ct2"
        XCTAssertEqual(settings.englishModel, RemoteTranscriptionSettings.defaultEnglishModel)
    }

    // MARK: - Withdrawing a pre-filled English model

    /// The mirror of the prefill. A pre-filled id only makes sense against the
    /// ivrit primary that caused it — carried over to a multilingual endpoint it
    /// names a model that endpoint doesn't have, breaking English outright,
    /// which is the exact failure the prefill is narrow to avoid.
    func test_prefill_isWithdrawn_whenPrimaryLeavesIvrit() {
        let settings = makeUpgrading(from: "ivrit-ai/whisper-large-v3-turbo-ct2")
        XCTAssertEqual(settings.englishModel, RemoteTranscriptionSettings.defaultEnglishModel,
                       "Precondition: pre-filled for the ivrit primary")

        settings.model = "whisper-1"
        XCTAssertEqual(settings.englishModel, "",
                       "A pre-filled id must not outlive the ivrit primary")
        XCTAssertEqual(settings.model(for: "en"), "whisper-1",
                       "English must route to the new multilingual primary")
        XCTAssertEqual(settings.model(for: "he"), "whisper-1")
    }

    /// Withdrawal is scoped to values Mila wrote. A model id the user typed is
    /// theirs and survives any change of primary.
    func test_prefill_withdrawal_leavesAUserValueAlone() {
        let settings = makeUpgrading(from: "ivrit-ai/whisper-large-v3-turbo-ct2",
                                     englishModel: "my-own/english-model")
        settings.model = "whisper-1"
        XCTAssertEqual(settings.englishModel, "my-own/english-model",
                       "Only auto-filled values are withdrawn")
    }

    /// A value the user typed over the pre-filled one becomes theirs, so the
    /// later switch away from ivrit must not withdraw it either.
    func test_prefill_withdrawal_leavesAValueTypedOverThePrefillAlone() {
        let settings = makeUpgrading(from: "ivrit-ai/whisper-large-v3-turbo-ct2")
        XCTAssertEqual(settings.englishModel, RemoteTranscriptionSettings.defaultEnglishModel)
        settings.englishModel = "my-own/english-model"   // user overrides the prefill

        settings.model = "whisper-1"
        XCTAssertEqual(settings.englishModel, "my-own/english-model")
    }

    /// Withdrawing is not the same as the user clearing: going back to an ivrit
    /// primary must pre-fill again rather than treat the blank as a decision.
    func test_prefill_refillsAfterRoundTripThroughAMultilingualPrimary() {
        let settings = makeUpgrading(from: "ivrit-ai/whisper-large-v3-turbo-ct2")
        settings.model = "whisper-1"
        XCTAssertEqual(settings.englishModel, "")

        settings.model = "ivrit-ai/whisper-large-v3-turbo-ct2"
        XCTAssertEqual(settings.englishModel, RemoteTranscriptionSettings.defaultEnglishModel,
                       "A withdrawal must not be recorded as an explicit clear")
    }

    /// The mirror of the refill test, and the case that separates a withdrawal
    /// from a clear: the user emptied the field by hand, so leaving ivrit and
    /// coming back must NOT resurrect the pre-filled id. Pins the guard order in
    /// `prefillEnglishModelIfNeeded` — `cleared` is checked before the primary
    /// is, so no route back to an ivrit primary can bypass it.
    func test_prefill_explicitClearSurvivesARoundTripThroughAMultilingualPrimary() {
        let settings = makeUpgrading(from: "ivrit-ai/whisper-large-v3-turbo-ct2")
        XCTAssertEqual(settings.englishModel, RemoteTranscriptionSettings.defaultEnglishModel,
                       "Precondition: pre-filled for the ivrit primary")
        settings.englishModel = ""   // user empties it by hand

        settings.model = "whisper-1"
        XCTAssertEqual(settings.englishModel, "")

        settings.model = "ivrit-ai/whisper-large-v3-turbo-ct2"
        XCTAssertEqual(settings.englishModel, "",
                       "An explicit clear must outlast a round trip through another primary")
        XCTAssertEqual(settings.model(for: "en"), "ivrit-ai/whisper-large-v3-turbo-ct2")
    }

    /// The invariant holds across a relaunch too, not just an in-session edit —
    /// e.g. the primary was changed by a `.milaconfig` on a previous launch.
    func test_prefill_isWithdrawnOnLaunch_whenPersistedPrimaryIsNotIvrit() {
        let name = "RemoteTranscriptionSettingsTests.prefill.\(#function)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        suite.set("ivrit-ai/whisper-large-v3-turbo-ct2", forKey: "remote.model")

        let first = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: "\(name).apiKey")
        XCTAssertEqual(first.englishModel, RemoteTranscriptionSettings.defaultEnglishModel)
        // Primary swapped out from under the auto-filled value, then relaunch.
        suite.set("whisper-1", forKey: "remote.model")

        let relaunched = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: "\(name).apiKey")
        XCTAssertEqual(relaunched.englishModel, "")
        XCTAssertEqual(relaunched.model(for: "en"), "whisper-1")
    }

    /// The reverse sequence, end to end: a value the user typed against a
    /// multilingual primary must survive a detour through an ivrit primary and
    /// back. It was never Mila's to withdraw at any point along the way.
    func test_prefill_withdrawal_userValueSurvivesARoundTripThroughIvrit() {
        let settings = makeUpgrading(from: "whisper-1")
        XCTAssertEqual(settings.englishModel, "", "Precondition: multilingual, nothing pre-filled")

        settings.englishModel = "my-own/english-model"   // typed by hand
        settings.model = "ivrit-ai/whisper-large-v3-turbo-ct2"
        XCTAssertEqual(settings.englishModel, "my-own/english-model",
                       "The prefill must not overwrite a value the user already typed")

        settings.model = "whisper-1"
        XCTAssertEqual(settings.englishModel, "my-own/english-model",
                       "…and the withdrawal must not eat it on the way back either")
        XCTAssertEqual(settings.model(for: "en"), "my-own/english-model")
    }

    /// An `englishModel` that predates this code has no auto-filled marker, so
    /// it must be treated as the user's and never withdrawn.
    func test_prefill_withdrawal_leavesPreExistingValuesAlone() {
        let settings = makeUpgrading(from: "whisper-1", englishModel: "legacy/english-model")
        XCTAssertEqual(settings.englishModel, "legacy/english-model")
        settings.model = "Systran/faster-whisper-large-v3"
        XCTAssertEqual(settings.englishModel, "legacy/english-model")
    }

    func test_localBackend_doesNotReadKeychain() {
        // Seed a real token under an isolated key, then construct with the
        // default (local) backend. A local-only user must come up with an empty
        // apiKey and we must NOT have read the Keychain (which would prompt).
        let key = "RemoteTranscriptionSettingsTests.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        KeychainHelper.save(key: key, value: "sk-stored")
        defer { KeychainHelper.delete(key: key) }

        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.\(#function)")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.\(#function)")
        let settings = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: key)

        XCTAssertEqual(settings.backend, .local)
        XCTAssertEqual(settings.apiKey, "", "Local-only launch must not load the stored token")
    }

    func test_switchingToRemote_lazilyLoadsStoredToken() {
        let key = "RemoteTranscriptionSettingsTests.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        KeychainHelper.save(key: key, value: "sk-stored")
        defer { KeychainHelper.delete(key: key) }

        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.\(#function)")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.\(#function)")
        let settings = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: key)
        XCTAssertEqual(settings.apiKey, "")

        settings.backend = .remote
        XCTAssertEqual(settings.apiKey, "sk-stored",
                       "Switching to remote must lazily load the stored token")
    }

    func test_remoteBackendAtLaunch_loadsStoredToken() {
        // If remote was the persisted choice, the token should be present right
        // after construction (the one case where reading at launch is correct).
        let key = "RemoteTranscriptionSettingsTests.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        KeychainHelper.save(key: key, value: "sk-stored")
        defer { KeychainHelper.delete(key: key) }

        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.\(#function)")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.\(#function)")
        suite.set(TranscriptionBackend.remote.rawValue, forKey: "transcription.backend")
        let settings = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: key)

        XCTAssertEqual(settings.backend, .remote)
        XCTAssertEqual(settings.apiKey, "sk-stored")
    }

    func test_lazyLoad_doesNotClobberInProgressEdit() {
        // User typed a key before ever switching to remote. Switching must keep
        // their edit, not overwrite it with the stored value.
        let key = "RemoteTranscriptionSettingsTests.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        KeychainHelper.save(key: key, value: "sk-stored")
        defer { KeychainHelper.delete(key: key) }

        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.\(#function)")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.\(#function)")
        let settings = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: key)

        settings.apiKey = "sk-user-typed"
        settings.backend = .remote
        XCTAssertEqual(settings.apiKey, "sk-user-typed",
                       "An in-progress edit must not be clobbered by the lazy load")
    }

    func test_lazyLoad_isIdempotentAcrossBackendToggles() {
        // Once loaded, toggling local <-> remote must not re-read or clobber.
        let key = "RemoteTranscriptionSettingsTests.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        KeychainHelper.save(key: key, value: "sk-stored")
        defer { KeychainHelper.delete(key: key) }

        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.\(#function)")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.\(#function)")
        let settings = RemoteTranscriptionSettings(defaults: suite, apiKeyKeychainKey: key)

        settings.backend = .remote
        XCTAssertEqual(settings.apiKey, "sk-stored")
        // User clears the field, then flips back to local and to remote again.
        settings.apiKey = ""
        settings.backend = .local
        settings.backend = .remote
        XCTAssertEqual(settings.apiKey, "",
                       "Already-loaded token must not be re-read on a later switch")
    }

    func test_editingEndpointResetsTestStatus() async {
        // Stub the network so testConnection() actually seeds a non-idle
        // status (.ok), then assert that editing the endpoint resets it —
        // exercising the real reset path rather than a no-op from .idle.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubOKURLProtocol.self]
        let session = URLSession(configuration: config)
        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.reset")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.reset")
        let settings = RemoteTranscriptionSettings(
            defaults: suite,
            urlSession: session,
            apiKeyKeychainKey: "RemoteTranscriptionSettingsTests.reset.apiKey")
        settings.backend = .remote
        settings.endpoint = "https://example.com/v1"

        await settings.testConnection()
        guard case .ok = settings.testStatus else {
            return XCTFail("Expected testConnection to seed .ok, got \(settings.testStatus)")
        }

        settings.endpoint = "https://example.com/v2"
        XCTAssertEqual(settings.testStatus, .idle, "Editing the endpoint must reset the status")
    }

    func test_testConnection_failsOnAuthError() async {
        // A 401 from /models must surface as .failed with an actionable
        // "check the API key" message. This is the guard that would have
        // caught a bad key (e.g. `test-key-123`) at record-start — BEFORE a
        // whole recording was silently lost to per-utterance 401s. Its
        // absence is why CI never flagged the original bug: the remote E2E
        // suite only ever exercised the happy path against an accepting mock.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Stub401URLProtocol.self]
        let session = URLSession(configuration: config)
        let suite = UserDefaults(suiteName: "RemoteTranscriptionSettingsTests.auth401")!
        suite.removePersistentDomain(forName: "RemoteTranscriptionSettingsTests.auth401")
        let keychainKey = "RemoteTranscriptionSettingsTests.auth401.apiKey"
        defer { KeychainHelper.delete(key: keychainKey) }
        let settings = RemoteTranscriptionSettings(
            defaults: suite, urlSession: session, apiKeyKeychainKey: keychainKey)
        settings.backend = .remote
        settings.endpoint = "https://api.openai.com/v1"
        settings.apiKey = "test-key-123"

        await settings.testConnection()

        guard case .failed(let message) = settings.testStatus else {
            return XCTFail("Expected .failed for a 401, got \(settings.testStatus)")
        }
        XCTAssertTrue(message.contains("401"), "Failure should name the status code: \(message)")
    }

    // MARK: - evaluateProbe (pure response → status mapping)

    func test_evaluateProbe_returnsTranscriptOn2xx() {
        let json = Data(#"{"text":"שלום עולם","segments":[{"start":0,"end":1,"text":"שלום עולם"}]}"#.utf8)
        guard case .ok(let msg) = RemoteTranscriptionSettings.evaluateProbe(statusCode: 200, data: json) else {
            return XCTFail("Expected .ok for a 2xx with a transcription")
        }
        XCTAssertTrue(msg.contains("שלום עולם"), "The success status must surface the transcribed text: \(msg)")
    }

    func test_evaluateProbe_emptyTranscriptFails() {
        // A 2xx that transcribes to nothing (wrong model id, silent clip) is a
        // failure, not a pass — GET /models would have wrongly called this "ok".
        let json = Data(#"{"text":"   ","segments":[]}"#.utf8)
        guard case .failed = RemoteTranscriptionSettings.evaluateProbe(statusCode: 200, data: json) else {
            return XCTFail("Expected .failed when the server returns no transcription")
        }
    }

    func test_evaluateProbe_authFails() {
        guard case .failed(let msg) = RemoteTranscriptionSettings.evaluateProbe(statusCode: 403, data: Data()) else {
            return XCTFail("Expected .failed for 403")
        }
        XCTAssertTrue(msg.localizedCaseInsensitiveContains("auth"))
    }

    func test_evaluateProbe_serverErrorNamesStatus() {
        guard case .failed(let msg) = RemoteTranscriptionSettings.evaluateProbe(statusCode: 502, data: Data()) else {
            return XCTFail("Expected .failed for 502")
        }
        XCTAssertTrue(msg.contains("502"))
    }
}

/// Returns 200 + a valid transcription for any request — lets `testConnection()`
/// reach `.ok` (which now parses the transcribed text) without a real server.
private final class StubOKURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        let json = #"{"text":"שלום עולם","segments":[{"start":0,"end":1,"text":"שלום עולם"}]}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Returns 401 with an OpenAI-style error body — simulates a bad API key.
private final class Stub401URLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 401,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"message":"Incorrect API key provided: test-key-123"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class RemoteWhisperEngineParsingTests: XCTestCase {

    func test_parsesVerboseJSONSegments() throws {
        let json = """
        {
          "task": "transcribe",
          "language": "hebrew",
          "duration": 5.0,
          "text": "שלום עולם",
          "segments": [
            { "id": 0, "start": 0.0, "end": 2.5, "text": " שלום" },
            { "id": 1, "start": 2.5, "end": 5.0, "text": " עולם" }
          ]
        }
        """.data(using: .utf8)!

        let segments = try RemoteWhisperEngine.parseSegments(data: json)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 0.0)
        XCTAssertEqual(segments[1].end, 5.0)
        // Original text preserved (leading space intact for joining).
        XCTAssertEqual(segments[0].text, " שלום")
    }

    func test_fallsBackToSingleSegmentWhenNoSegments() throws {
        let json = """
        { "text": "hello world", "duration": 3.2 }
        """.data(using: .utf8)!

        let segments = try RemoteWhisperEngine.parseSegments(data: json)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 0)
        XCTAssertEqual(segments[0].end, 3.2)
        XCTAssertEqual(segments[0].text, "hello world")
    }

    func test_throwsOnEmptyResult() {
        let json = """
        { "text": "   ", "segments": [] }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try RemoteWhisperEngine.parseSegments(data: json))
    }

    func test_multipartBodyContainsRequiredFields() {
        let audio = Data([0x00, 0x01, 0x02, 0x03])
        let body = RemoteWhisperEngine.multipartBody(boundary: "B",
                                                     audio: audio,
                                                     model: "whisper-1",
                                                     language: "he")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"model\""))
        XCTAssertTrue(text.contains("whisper-1"))
        XCTAssertTrue(text.contains("name=\"response_format\""))
        XCTAssertTrue(text.contains("verbose_json"))
        XCTAssertTrue(text.contains("name=\"language\""))
        XCTAssertTrue(text.contains("filename=\"audio.m4a\""))
        XCTAssertTrue(text.contains("--B--"), "Must be terminated with the closing boundary")
    }

    func test_multipartBodyOmitsLanguageWhenAuto() {
        let body = RemoteWhisperEngine.multipartBody(boundary: "B",
                                                     audio: Data(),
                                                     model: "whisper-1",
                                                     language: "auto")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("name=\"language\""),
                       "Auto-detect must omit the language field")
    }
}
