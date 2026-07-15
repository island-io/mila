import XCTest
@testable import Mila

// Test home for OpenAI-compatible endpoint support (see
// llm-artifacts/openai_compatible_endpoint_*). Grown incrementally per the
// implementation plan's phases; each phase adds the test class for the unit it
// proves. HTTP is stubbed via a transport-injection seam (RecordingTransport),
// not the per-session URLProtocol convention used by the transcription tests —
// see the plan's TDD-discipline note.

// MARK: - Phase 4: LLMSettings OpenAI readiness + keychain

@MainActor
final class LLMSettingsOpenAIReadinessTests: XCTestCase {

    private func makeSettings(_ label: String = #function) -> LLMSettings {
        let suite = UserDefaults(suiteName: "LLMSettingsOpenAI.\(label)")!
        suite.removePersistentDomain(forName: "LLMSettingsOpenAI.\(label)")
        return LLMSettings(defaults: suite,
                           apiKeyKeychainKey: "LLMSettingsOpenAI.\(label).apiKey")
    }

    /// AC-READY-01
    func test_isConfigured_falseForNone() {
        let s = makeSettings()
        XCTAssertEqual(s.tool, .none)
        XCTAssertFalse(s.isConfigured)
    }

    /// AC-READY-02 / AC-READY-03 — the OpenAI tool requires a non-blank base URL.
    func test_isConfigured_falseForOpenAI_whenBaseURLEmpty() {
        let s = makeSettings()
        s.tool = .openaiCompatible
        s.openAIBaseURL = ""
        XCTAssertFalse(s.isConfigured)
    }

    func test_isConfigured_falseForOpenAI_whenBaseURLWhitespace() {
        let s = makeSettings()
        s.tool = .openaiCompatible
        s.openAIBaseURL = "   \n  "
        XCTAssertFalse(s.isConfigured)
    }

    /// AC-READY-04 — a base URL alone is NOT enough; the OpenAI HTTP path
    /// can't pick its own model, so a blank model name means any auto-title /
    /// summary request is doomed. `isConfigured` must require both (CodeRabbit
    /// #3 / `.claude/rules/feature-gates.md` — "enabled AND ready").
    func test_isConfigured_falseForOpenAI_whenModelNameEmpty() {
        let s = makeSettings()
        s.tool = .openaiCompatible
        s.openAIBaseURL = "https://api.openai.com/v1"
        s.openAIModelName = ""
        XCTAssertFalse(s.isConfigured)
    }

    /// AC-READY-04 — base URL + model name together mark the tool ready.
    func test_isConfigured_trueForOpenAI_whenBaseURLAndModelPresent() {
        let s = makeSettings()
        s.tool = .openaiCompatible
        s.openAIBaseURL = "https://api.openai.com/v1"
        s.openAIModelName = "gpt-4o-mini"
        XCTAssertTrue(s.isConfigured)
    }

    /// AC-READY — a local/anonymous endpoint is configured without a key, but
    /// still needs a model name (the API key is the only optional field).
    func test_isConfigured_trueForOpenAI_evenWhenAPIKeyEmpty() {
        let s = makeSettings()
        s.tool = .openaiCompatible
        s.openAIBaseURL = "http://localhost:11434/v1"
        s.openAIModelName = "llama3.2"
        s.openAIAPIKey = ""
        XCTAssertTrue(s.isConfigured)
    }

    /// AC-READY — the existing CLI tools stay configured regardless of OpenAI state.
    func test_isConfigured_trueForClaude_regardlessOfOpenAIFields() {
        let s = makeSettings()
        s.tool = .claude
        s.openAIBaseURL = ""
        XCTAssertTrue(s.isConfigured)
    }
}

@MainActor
final class OpenAIAPIKeyKeychainTests: XCTestCase {

    private func makeSettings(_ label: String = #function) -> LLMSettings {
        let key = "LLMSettingsOpenAIKeychain.\(label).apiKey"
        KeychainHelper.delete(key: key)
        let suite = UserDefaults(suiteName: "LLMSettingsOpenAIKeychain.\(label)")!
        suite.removePersistentDomain(forName: "LLMSettingsOpenAIKeychain.\(label)")
        return LLMSettings(defaults: suite, apiKeyKeychainKey: key)
    }

    /// AC-KEY-01 — the key is persisted to the Keychain, never UserDefaults.
    func test_settingAPIKey_writesToKeychain_notUserDefaults() {
        let key = "LLMSettingsOpenAIKeychain.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        defer { KeychainHelper.delete(key: key) }
        let suite = UserDefaults(suiteName: "LLMSettingsOpenAIKeychain.\(#function)")!
        suite.removePersistentDomain(forName: "LLMSettingsOpenAIKeychain.\(#function)")
        let s = LLMSettings(defaults: suite, apiKeyKeychainKey: key)

        s.openAIAPIKey = "sk-secret"
        XCTAssertEqual(KeychainHelper.load(key: key), "sk-secret")
        XCTAssertNil(suite.string(forKey: "llm.openai.apiKey"),
                     "The API key must never land in UserDefaults")
    }

    /// AC-KEY-02 — restoring at launch when OpenAI was the persisted tool.
    func test_restoredFromKeychain_onInit_whenToolIsOpenAI() {
        let key = "LLMSettingsOpenAIKeychain.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        KeychainHelper.save(key: key, value: "sk-stored")
        defer { KeychainHelper.delete(key: key) }

        let suite = UserDefaults(suiteName: "LLMSettingsOpenAIKeychain.\(#function)")!
        suite.removePersistentDomain(forName: "LLMSettingsOpenAIKeychain.\(#function)")
        suite.set(LLMTool.openaiCompatible.rawValue, forKey: "llm.tool")
        let s = LLMSettings(defaults: suite, apiKeyKeychainKey: key)

        XCTAssertEqual(s.tool, .openaiCompatible)
        XCTAssertEqual(s.openAIAPIKey, "sk-stored",
                       "Stored key must load at init when OpenAI is the persisted tool")
    }

    /// AC-KEY-03 — an in-progress edit must survive the lazy load on tool switch.
    func test_notOverwrittenByStoredValue_whenUserTypedOne() {
        let key = "LLMSettingsOpenAIKeychain.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        KeychainHelper.save(key: key, value: "sk-stored")
        defer { KeychainHelper.delete(key: key) }

        let suite = UserDefaults(suiteName: "LLMSettingsOpenAIKeychain.\(#function)")!
        suite.removePersistentDomain(forName: "LLMSettingsOpenAIKeychain.\(#function)")
        let s = LLMSettings(defaults: suite, apiKeyKeychainKey: key)
        XCTAssertEqual(s.tool, .none)

        s.openAIAPIKey = "sk-user-typed"
        s.tool = .openaiCompatible
        XCTAssertEqual(s.openAIAPIKey, "sk-user-typed",
                       "An in-progress edit must not be clobbered by the lazy load")
    }

    /// AC-KEY-04 (idempotency) — once loaded, toggling the tool must not re-read
    /// or clobber the key. Mirrors `RemoteTranscriptionSettingsTests`.
    func test_lazyLoad_isIdempotentAcrossToolToggles() {
        let key = "LLMSettingsOpenAIKeychain.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        KeychainHelper.save(key: key, value: "sk-stored")
        defer { KeychainHelper.delete(key: key) }

        let suite = UserDefaults(suiteName: "LLMSettingsOpenAIKeychain.\(#function)")!
        suite.removePersistentDomain(forName: "LLMSettingsOpenAIKeychain.\(#function)")
        let s = LLMSettings(defaults: suite, apiKeyKeychainKey: key)

        s.tool = .openaiCompatible
        XCTAssertEqual(s.openAIAPIKey, "sk-stored")
        s.openAIAPIKey = ""
        s.tool = .claude
        s.tool = .openaiCompatible
        XCTAssertEqual(s.openAIAPIKey, "",
                       "An already-cleared key must not be re-read on a later switch")
    }

    /// AC-KEY-05 — clearing the field removes the Keychain item.
    func test_emptyAPIKey_deletesKeychainItem() {
        let key = "LLMSettingsOpenAIKeychain.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        defer { KeychainHelper.delete(key: key) }
        let suite = UserDefaults(suiteName: "LLMSettingsOpenAIKeychain.\(#function)")!
        suite.removePersistentDomain(forName: "LLMSettingsOpenAIKeychain.\(#function)")
        let s = LLMSettings(defaults: suite, apiKeyKeychainKey: key)

        s.openAIAPIKey = "sk-then-cleared"
        XCTAssertEqual(KeychainHelper.load(key: key), "sk-then-cleared")
        s.openAIAPIKey = ""
        XCTAssertNil(KeychainHelper.load(key: key),
                     "An empty key must delete the Keychain item, not store an empty string")
    }
}

// MARK: - Phase 3: OpenAIClient.parse (pure response/error parser)

@MainActor
final class OpenAIResponseParserTests: XCTestCase {

    private func http(_ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
        let data = Data(body.utf8)
        let resp = HTTPURLResponse(url: URL(string: "https://x/v1/chat/completions")!,
                                   statusCode: status, httpVersion: nil,
                                   headerFields: ["Content-Type": "application/json"])!
        return (data, resp)
    }

    private func expectFailure(_ result: Result<String, Error>) -> Error {
        switch result {
        case .success:
            // `XCTFail` returns Void and doesn't halt execution; force-casting it
            // to `Error` (the old `as! Error`) traps on regression. Record the
            // failure, then hand back a sentinel so the caller's assertion can
            // run instead of crashing the test host. (CodeRabbit #5.)
            XCTFail("expected failure, got success")
            return NSError(domain: "OpenAIResponseParserTests", code: 1, userInfo: nil)
        case .failure(let e): return e
        }
    }

    /// AC-RESP-01
    func test_parse_2xx_returnsFirstChoiceContentTrimmed() {
        let (data, resp) = http(200, #"{"choices":[{"message":{"role":"assistant","content":"  hello  "}}]}"#)
        let result = OpenAIClient.parse(data: data, response: resp)
        XCTAssertEqual(try? result.get(), "hello")
    }

    /// AC-RESP-02
    func test_parse_2xx_multiChoice_usesFirstChoice() {
        let body = #"{"choices":[{"message":{"role":"assistant","content":"first"}},{"message":{"role":"assistant","content":"second"}}]}"#
        let (data, resp) = http(200, body)
        XCTAssertEqual(try? OpenAIClient.parse(data: data, response: resp).get(), "first")
    }

    /// AC-RESP-03
    func test_parse_2xx_emptyChoices_throwsEmptyOutput() {
        let (data, resp) = http(200, #"{"choices":[]}"#)
        let err = expectFailure(OpenAIClient.parse(data: data, response: resp))
        XCTAssertTrue(err is OpenAIRequestError, "got \(type(of: err))")
        XCTAssertEqual(err as? OpenAIRequestError, .emptyOutput)
    }

    /// AC-ERR-01
    func test_parse_401_decodesErrorMessage_readableAuthError() {
        let (data, resp) = http(401, #"{"error":{"message":"Incorrect API key provided: sk-xx"}}"#)
        let err = expectFailure(OpenAIClient.parse(data: data, response: resp))
        guard case .auth(let msg)? = err as? OpenAIRequestError else {
            return XCTFail("expected .auth, got \(err)")
        }
        XCTAssertTrue(msg.contains("API key"), "auth message should surface the server text: \(msg)")
        XCTAssertNotNil((err as? LocalizedError)?.errorDescription)
    }

    /// AC-ERR-02
    func test_parse_404_modelNotFound_readableMessage() {
        let (data, resp) = http(404, #"{"error":{"message":"The model 'gpt-5' does not exist"}}"#)
        let err = expectFailure(OpenAIClient.parse(data: data, response: resp))
        guard case .notFound(let msg)? = err as? OpenAIRequestError else {
            return XCTFail("expected .notFound, got \(err)")
        }
        XCTAssertTrue(msg.lowercased().contains("model"), "notFound message should mention the model: \(msg)")
    }

    /// AC-ERR-03
    func test_parse_500_includesStatusAndMessage() {
        let (data, resp) = http(500, #"{"error":{"message":"internal boom"}}"#)
        let err = expectFailure(OpenAIClient.parse(data: data, response: resp))
        guard case .server(let status, let msg)? = err as? OpenAIRequestError else {
            return XCTFail("expected .server, got \(err)")
        }
        XCTAssertEqual(status, 500)
        XCTAssertTrue(msg.contains("internal boom"), "server message should include server text: \(msg)")
    }

    /// AC-ERR-04 — undecodable error body falls back to a status-only message.
    func test_parse_undecodableErrorBody_fallsBackToHTTPStatus() {
        let (data, resp) = http(502, "not-json-at-all")
        let err = expectFailure(OpenAIClient.parse(data: data, response: resp))
        guard case .server(let status, let msg)? = err as? OpenAIRequestError else {
            return XCTFail("expected .server fallback, got \(err)")
        }
        XCTAssertEqual(status, 502)
        XCTAssertTrue(msg.contains("502"), "fallback should name the status: \(msg)")
    }

    /// AC-ERR-06 — every HTTP error case is a readable LocalizedError.
    func test_allHTTPErrors_conformToLocalizedError() {
        let cases: [OpenAIRequestError] = [
            .auth("bad key"),
            .notFound("no model"),
            .server(status: 500, message: "boom"),
            .emptyOutput
        ]
        for e in cases {
            XCTAssertNotNil((e as LocalizedError).errorDescription,
                            "\(e) must provide an errorDescription")
        }
    }
}

// MARK: - Phase 2: OpenAIClient.makeRequest (pure request builder)

@MainActor
final class OpenAIRequestBuilderTests: XCTestCase {

    private func bodyJSON(_ request: URLRequest) -> [String: Any] {
        let data = request.httpBody ?? Data()
        // `try!` would trap on a malformed body (and `XCTFail` doesn't halt
        // execution, so a later `as!`/subscript could still crash). Decode
        // softly and record the failure. (CodeRabbit #5.)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            XCTFail("request body is not a JSON object: \(String(data: data, encoding: .utf8) ?? "<binary>")")
            return [:]
        }
        return dict
    }

    /// AC-REQ-01 — `<trimmed baseURL>/chat/completions`, trailing-slash tolerant.
    func test_makeRequest_postURL_joinsBaseURLWithChatCompletions() throws {
        let r = try OpenAIClient.makeRequest(baseURL: "https://api.openai.com/v1",
                                         model: "gpt-4o-mini", prompt: "p",
                                         transcript: "t", summary: "",
                                         apiKey: "k", jsonMode: false, temperature: nil)
        XCTAssertEqual(r.url?.absoluteString,
                       "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(r.httpMethod, "POST")
    }

    func test_makeRequest_stripsTrailingSlashFromBaseURL() throws {
        let r = try OpenAIClient.makeRequest(baseURL: "https://api.openai.com/v1/",
                                         model: "m", prompt: "p", transcript: "t",
                                         summary: "", apiKey: "k", jsonMode: false, temperature: nil)
        XCTAssertEqual(r.url?.absoluteString,
                       "https://api.openai.com/v1/chat/completions")
    }

    /// AC-REQ-02
    func test_makeRequest_setsContentTypeJSON() throws {
        let r = try OpenAIClient.makeRequest(baseURL: "https://x/v1", model: "m",
                                         prompt: "p", transcript: "t", summary: "",
                                         apiKey: "k", jsonMode: false, temperature: nil)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    /// AC-REQ-03
    func test_makeRequest_setsBearerAuthorization_whenKeyPresent() throws {
        let r = try OpenAIClient.makeRequest(baseURL: "https://x/v1", model: "m",
                                         prompt: "p", transcript: "t", summary: "",
                                         apiKey: "sk-abc", jsonMode: false, temperature: nil)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer sk-abc")
    }

    func test_makeRequest_omitsAuthorizationHeader_whenKeyEmpty() throws {
        let r = try OpenAIClient.makeRequest(baseURL: "https://x/v1", model: "m",
                                         prompt: "p", transcript: "t", summary: "",
                                         apiKey: "", jsonMode: false, temperature: nil)
        XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
    }

    /// AC-REQ-04 — a single `user` message holding the composed prompt.
    func test_makeRequest_bodyMessages_singleUserMessageWithComposedPrompt() throws {
        let r = try OpenAIClient.makeRequest(baseURL: "https://x/v1", model: "m",
                                         prompt: "Summarize.", transcript: "hello world",
                                         summary: "gist", apiKey: "k", jsonMode: false, temperature: nil)
        let body = bodyJSON(r)
        let messages = body["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?.first?["role"], "user")
        let expected = LLMRunner.composedPrompt("Summarize.", transcript: "hello world", summary: "gist")
        XCTAssertEqual(messages?.first?["content"], expected)
    }

    /// AC-REQ-05 — model name is trimmed.
    func test_makeRequest_bodyModel_equalsTrimmedModelName() throws {
        let r = try OpenAIClient.makeRequest(baseURL: "https://x/v1", model: "  gpt-4o-mini  ",
                                         prompt: "p", transcript: "t", summary: "",
                                         apiKey: "k", jsonMode: false, temperature: nil)
        XCTAssertEqual(bodyJSON(r)["model"] as? String, "gpt-4o-mini")
    }

    /// AC-REQ-06 — response_format present iff jsonMode.
    func test_makeRequest_includesResponseFormat_whenJSONModeRequested() throws {
        let r = try OpenAIClient.makeRequest(baseURL: "https://x/v1", model: "m",
                                         prompt: "p", transcript: "t", summary: "",
                                         apiKey: "k", jsonMode: true, temperature: nil)
        let rf = bodyJSON(r)["response_format"] as? [String: String]
        XCTAssertEqual(rf?["type"], "json_object")
    }

    func test_makeRequest_omitsResponseFormat_whenJSONModeNotRequested() throws {
        let r = try OpenAIClient.makeRequest(baseURL: "https://x/v1", model: "m",
                                         prompt: "p", transcript: "t", summary: "",
                                         apiKey: "k", jsonMode: false, temperature: nil)
        XCTAssertNil(bodyJSON(r)["response_format"])
    }

    /// AC-REQ-07 — non-streaming only.
    func test_makeRequest_streamAlwaysFalse() throws {
        let r = try OpenAIClient.makeRequest(baseURL: "https://x/v1", model: "m",
                                         prompt: "p", transcript: "t", summary: "",
                                         apiKey: "k", jsonMode: true, temperature: nil)
        XCTAssertEqual(bodyJSON(r)["stream"] as? Bool, false)
    }

    /// AC-REQ-09 — temperature included iff non-nil.
    func test_makeRequest_includesTemperature_whenSet() throws {
        let r = try OpenAIClient.makeRequest(baseURL: "https://x/v1", model: "m",
                                         prompt: "p", transcript: "t", summary: "",
                                         apiKey: "k", jsonMode: false, temperature: 0.2)
        XCTAssertEqual(bodyJSON(r)["temperature"] as? Double, 0.2)
    }

    func test_makeRequest_omitsTemperature_whenNil() throws {
        let r = try OpenAIClient.makeRequest(baseURL: "https://x/v1", model: "m",
                                         prompt: "p", transcript: "t", summary: "",
                                         apiKey: "k", jsonMode: false, temperature: nil)
        XCTAssertNil(bodyJSON(r)["temperature"])
    }

    /// AC-REQ-11 (issue celarent7/mila#1) — a malformed base URL must surface
    /// a typed `invalidEndpoint` error instead of crashing the app via a
    /// force-unwrap. An internal space (not just leading/trailing) makes
    /// `URL(string:)` return nil.
    func test_makeRequest_throwsInvalidEndpoint_forMalformedBaseURL() {
        XCTAssertThrowsError(try OpenAIClient.makeRequest(baseURL: "https://api.open ai.com/v1",
                                                          model: "m", prompt: "p",
                                                          transcript: "t", summary: "",
                                                          apiKey: "k", jsonMode: false,
                                                          temperature: nil)) { error in
            XCTAssertEqual(error as? OpenAIRequestError, .invalidEndpoint("https://api.open ai.com/v1"))
        }
    }

    /// AC-REQ-12 (issue celarent7/mila#1) — `runOpenAICompatible` must surface
    /// the typed `invalidEndpoint` error (readable in the rename / Send sheet)
    /// rather than crashing, when the base URL is malformed.
    func test_runOpenAICompatible_throwsInvalidEndpoint_forMalformedBaseURL() async throws {
        struct AlwaysReach: OpenAITransport {
            func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
                throw URLError(.badServerResponse)
            }
        }
        do {
            _ = try await LLMRunner.runOpenAICompatible(
                prompt: "p", transcript: "t", summary: "", model: "m",
                timeout: 30, baseURL: "https://api.open ai.com/v1",
                apiKey: "k", jsonMode: false, temperature: nil,
                transport: AlwaysReach())
            XCTFail("Expected invalidEndpoint for a malformed base URL")
        } catch let error as OpenAIRequestError {
            XCTAssertEqual(error, .invalidEndpoint("https://api.open ai.com/v1"))
        } catch {
            XCTFail("Expected OpenAIRequestError.invalidEndpoint, got \(error)")
        }
    }

    /// AC-REQ-13 (issue celarent7/mila#1) — `diagnoseOpenAICompatible` is
    /// non-throwing, so a malformed base URL must land in `setupError` (and
    /// NOT set `didLaunch`), not crash.
    func test_diagnoseOpenAICompatible_reportsInvalidEndpoint_asSetupError() async {
        let result = await LLMRunner.diagnoseOpenAICompatible(
            prompt: "p", transcript: "t", summary: "", model: "m",
            timeout: 30, baseURL: "https://api.open ai.com/v1",
            apiKey: "k", jsonMode: false, transport: nil)
        XCTAssertFalse(result.didLaunch, "An invalid endpoint must not count as a launch")
        XCTAssertNotNil(result.setupError)
        XCTAssertTrue(result.setupError?.contains("not a valid endpoint URL") ?? false,
                      "setupError should name the invalid endpoint: \(result.setupError ?? "")")
    }

    /// AC-REQ-10 — the HTTP tool contributes no argv; the runner's HTTP branch
    /// never reaches `arguments`.
    func test_llmTool_arguments_returnsEmptyForOpenAICompatible() {
        XCTAssertTrue(LLMTool.openaiCompatible.arguments(prompt: "p").isEmpty)
        XCTAssertEqual(LLMTool.openaiCompatible.executableName, "")
        XCTAssertEqual(LLMTool.openaiCompatible.displayName, "OpenAI Compatible")
    }
}

// MARK: - Phase 1: OpenAIProvider preset enum (pure)

@MainActor
final class OpenAIProviderTests: XCTestCase {

    /// AC-PRESET-01 — the closed set of presets the UI picker offers.
    func test_provider_allCases_containsExpectedPresets() {
        let names = OpenAIProvider.allCases.map(\.rawValue)
        XCTAssertEqual(names, [
            "ollamaLocal", "ollamaCloud", "openai",
            "openrouter", "groq", "deepseek", "custom"
        ])
    }

    /// AC-PRESET-02 — each preset ships a base URL (empty for `.custom`).
    func test_provider_baseURL_matchesExpectedForEachPreset() {
        XCTAssertEqual(OpenAIProvider.ollamaLocal.baseURL, "http://localhost:11434/v1")
        XCTAssertEqual(OpenAIProvider.ollamaCloud.baseURL, "https://ollama.com/v1")
        XCTAssertEqual(OpenAIProvider.openai.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(OpenAIProvider.openrouter.baseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(OpenAIProvider.groq.baseURL, "https://api.groq.com/openai/v1")
        XCTAssertEqual(OpenAIProvider.deepseek.baseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(OpenAIProvider.custom.baseURL, "")
    }

    /// AC-PRESET-03 — only a local server may run without an API key.
    func test_provider_requiresAPIKey_trueExceptOllamaLocal() {
        XCTAssertFalse(OpenAIProvider.ollamaLocal.requiresAPIKey,
                       "A local Ollama server has no auth by default")
        for p in OpenAIProvider.allCases where p != .ollamaLocal {
            XCTAssertTrue(p.requiresAPIKey, "\(p.rawValue) must require an API key")
        }
    }

    /// AC-PRESET-06 — every preset carries its OWN default model name; there is
    /// no single hardcoded `llama3` fallback. (The locale-aware default-model
    /// mechanism in `ModelManager` is Whisper-transcription-only and does not
    /// apply here — see C2.)
    func test_provider_defaultModelName_isPerPreset_notHardcodedLlama3() {
        for p in OpenAIProvider.allCases {
            XCTAssertFalse(p.defaultModelName == "llama3",
                           "\(p.rawValue) must not fall back to the bare 'llama3' default")
        }
        // Non-custom presets ship a concrete default; custom is user-supplied.
        for p in OpenAIProvider.allCases where p != .custom {
            XCTAssertFalse(p.defaultModelName.isEmpty,
                           "\(p.rawValue) must ship a default model name")
        }
        XCTAssertEqual(OpenAIProvider.custom.defaultModelName, "")
    }

    // MARK: Preset fill / persistence (lives here because it exercises the
    // OpenAIProvider preset values through LLMSettings.applyPreset).

    private func makeSettings(_ label: String = #function) -> LLMSettings {
        let suite = UserDefaults(suiteName: "OpenAIProviderTests.\(label)")!
        suite.removePersistentDomain(forName: "OpenAIProviderTests.\(label)")
        let key = "OpenAIProviderTests.\(label).apiKey"
        KeychainHelper.delete(key: key)
        return LLMSettings(defaults: suite, apiKeyKeychainKey: key)
    }

    /// AC-PRESET-04 — picking a preset fills empty base URL + model fields.
    func test_selectingPreset_fillsBaseURLAndModel_whenFieldsEmpty() {
        let s = makeSettings()
        // First selection: provider starts at the `.custom` default.
        s.applyPreset(.openai, previous: .custom)
        XCTAssertEqual(s.openAIBaseURL, OpenAIProvider.openai.baseURL)
        XCTAssertEqual(s.openAIModelName, OpenAIProvider.openai.defaultModelName)
        XCTAssertEqual(s.openAIProvider, .openai)
    }

    /// AC-PRESET-04 — a user-customized base URL survives a preset change.
    func test_selectingPreset_doesNotOverwriteCustomBaseURL() {
        let s = makeSettings()
        s.openAIBaseURL = "https://my-hosted.example/v1"
        s.openAIModelName = "my-model"
        s.applyPreset(.groq, previous: .custom)
        XCTAssertEqual(s.openAIBaseURL, "https://my-hosted.example/v1",
                       "A custom base URL must not be overwritten by a preset")
        XCTAssertEqual(s.openAIModelName, "my-model",
                       "A custom model must not be overwritten by a preset")
        XCTAssertEqual(s.openAIProvider, .groq)
    }

    /// AC-PRESET-04 — switching presets replaces the *previous* preset's
    /// default values but not a user edit.
    func test_selectingPreset_overwritesPreviousPresetDefault() {
        let s = makeSettings()
        s.applyPreset(.openai, previous: .custom)   // fills openai defaults
        XCTAssertEqual(s.openAIBaseURL, OpenAIProvider.openai.baseURL)
        s.applyPreset(.groq, previous: .openai)     // openai defaults → groq defaults
        XCTAssertEqual(s.openAIBaseURL, OpenAIProvider.groq.baseURL)
        XCTAssertEqual(s.openAIModelName, OpenAIProvider.groq.defaultModelName)
    }

    /// AC-PRESET-06 (issue celarent7/mila#2) — switching presets via the
    /// Settings `Picker` must actually update the base URL + model. The
    /// `Picker` binding sets `openAIProvider` to the new value *before*
    /// `.onChange` fires, so this test reproduces that exact order (set the
    /// provider to the new preset first, then call `applyPreset(new,
    /// previous: old)`). With the old `let previous = openAIProvider` read,
    /// `previous` would be `.groq` (already updated) and the fields would
    /// NOT change — the endpoint would stay pointed at OpenAI.
    func test_selectingPreset_viaBindingOrder_updatesBaseURLAndModel() {
        let s = makeSettings()
        // Start on OpenAI, fields holding openai defaults (as a real first
        // pick would leave them).
        s.openAIProvider = .openai
        s.openAIBaseURL = OpenAIProvider.openai.baseURL
        s.openAIModelName = OpenAIProvider.openai.defaultModelName
        // Picker binding updates openAIProvider FIRST ...
        s.openAIProvider = .groq
        // ... then .onChange fires with old=.openai, new=.groq.
        s.applyPreset(.groq, previous: .openai)
        XCTAssertEqual(s.openAIProvider, .groq)
        XCTAssertEqual(s.openAIBaseURL, OpenAIProvider.groq.baseURL,
                       "Switching OpenAI→Groq must update the base URL")
        XCTAssertEqual(s.openAIModelName, OpenAIProvider.groq.defaultModelName,
                       "Switching OpenAI→Groq must update the model name")
    }

    /// AC-PRESET-05 — OpenAI fields survive a settings re-creation (same defaults).
    func test_openAIFields_persistAcrossInstances() {
        let suite = UserDefaults(suiteName: "OpenAIProviderTests.\(#function)")!
        suite.removePersistentDomain(forName: "OpenAIProviderTests.\(#function)")
        let key = "OpenAIProviderTests.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        defer { KeychainHelper.delete(key: key) }

        let first = LLMSettings(defaults: suite, apiKeyKeychainKey: key)
        first.tool = .openaiCompatible
        first.openAIProvider = .deepseek
        first.openAIBaseURL = "https://api.deepseek.com/v1"
        first.openAIModelName = "deepseek-chat"
        first.openAIAPIKey = "sk-persist"

        let second = LLMSettings(defaults: suite, apiKeyKeychainKey: key)
        XCTAssertEqual(second.tool, .openaiCompatible)
        XCTAssertEqual(second.openAIProvider, .deepseek)
        XCTAssertEqual(second.openAIBaseURL, "https://api.deepseek.com/v1")
        XCTAssertEqual(second.openAIModelName, "deepseek-chat")
        XCTAssertEqual(second.openAIAPIKey, "sk-persist",
                       "API key must round-trip through the Keychain")
    }
}

// MARK: - Phase 6: transport protocol + LLMRunner.run HTTP branch

/// Test-only `OpenAITransport` stub. Records every `URLRequest` it was handed
/// and returns a canned `(HTTPURLResponse, Data)` or throws a canned error —
/// so `LLMRunner.run`'s `.openaiCompatible` branch can be driven end-to-end
/// without a network. `hangUntilCancelled` models `URLSession`'s cancel
/// behaviour: `send` suspends until the owning Task is cancelled, then throws
/// `URLError(.cancelled)` (and yields the canned response on a manual
/// `release()` if one was staged — so the "cancel wins over a late response"
/// assertion is expressible).
final class RecordingTransport: OpenAITransport, @unchecked Sendable {
    // `requests` and `hang` are touched from the `send` task and, for `hang`,
    // from the cancellation handler / `release()` — which run on different
    // contexts. The lock serializes all of those accesses so the
    // `@unchecked Sendable` conformance is honest and a cancellation race can
    // neither miss the wakeup nor double-resume the `CheckedContinuation`
    // (a double resume is a fatal error). `cannedResponse`/`cannedError`/
    // `hangUntilCancelled` are set before the `send` task starts and only read
    // inside it, so they need no guard.
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }
    var cannedResponse: (HTTPURLResponse, Data)?
    var cannedError: Error?
    var hangUntilCancelled = false
    private var hang: CheckedContinuation<Void, Never>?

    // Explicit deinit to satisfy the `required_deinit` lint (CodeRabbit #6).
    // Intentionally a no-op: `hang` is a `CheckedContinuation`, and resuming it
    // here would crash if `release()`/cancellation already resumed it (a
    // `CheckedContinuation` resumed twice is a fatal error). The suspended
    // continuation is owned by the test Task that's cancelled during teardown,
    // so it resolves with the test's lifetime — we don't resume from deinit.
    deinit {}

    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        lock.lock()
        _requests.append(request)
        lock.unlock()
        if let cannedError { throw cannedError }
        if hangUntilCancelled {
            let cancelled: Bool = await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    self.lock.lock()
                    if Task.isCancelled {
                        self.lock.unlock()
                        cont.resume(); return
                    }
                    self.hang = cont
                    self.lock.unlock()
                }
                return Task.isCancelled
            } onCancel: {
                // Route through `release()` so there's a single resume path;
                // the lock + nil-after-extract makes a double resume impossible
                // even if cancellation and a manual `release()` both fire.
                self.release()
            }
            if cancelled || Task.isCancelled { throw URLError(.cancelled) }
            // Resumed by `release()` with a staged response.
            if let cannedResponse { return cannedResponse }
            throw URLError(.resourceUnavailable)
        }
        guard let cannedResponse else { throw URLError(.resourceUnavailable) }
        return cannedResponse
    }

    /// Release a hanging `send` (for the "late response" assertion). Extracts
    /// the continuation under the lock and resumes *after* unlocking, so a
    /// concurrent cancellation (or a second `release()`) finds `hang == nil`
    /// and no-ops instead of double-resuming.
    func release() {
        lock.lock()
        let cont = hang
        hang = nil
        lock.unlock()
        cont?.resume()
    }
}

final class OpenAITransportTests: XCTestCase {

    private func response(status: Int, body: String) -> (HTTPURLResponse, Data) {
        let url = URL(string: "http://localhost:11434/v1/chat/completions")!
        let http = HTTPURLResponse(url: url, statusCode: status,
                                   httpVersion: nil, headerFields: nil)!
        return (http, Data(body.utf8))
    }

    // Phase 6.0.5 — pins the new `run` signature + the defense-in-depth guard.
    func test_run_openAICompatible_withoutBaseURL_throwsToolDisabled() async throws {
        let transport = RecordingTransport()
        do {
            _ = try await LLMRunner.run(tool: .openaiCompatible,
                                        prompt: "Summarize", transcript: "hello",
                                        executablePathOverride: nil, model: "m",
                                        timeout: 10,
                                        openAIBaseURL: nil, openAIAPIKey: "k",
                                        jsonMode: false, transport: transport)
            XCTFail("expected LLMRunnerError.toolDisabled")
        } catch LLMRunnerError.toolDisabled {
            // pass
        } catch {
            XCTFail("expected .toolDisabled, got \(error)")
        }
        XCTAssertEqual(transport.requests.count, 0,
                       "no base URL ⇒ transport must never be invoked")
    }

    // AC-RESP-01 end-to-end.
    func test_run_success_endToEnd_returnsContent() async throws {
        let transport = RecordingTransport()
        transport.cannedResponse = response(
            status: 200,
            body: #"{"choices":[{"message":{"role":"assistant","content":"Hello there"}}]}"#)
        let out = try await LLMRunner.run(tool: .openaiCompatible,
                                          prompt: "Greet", transcript: "hi",
                                          executablePathOverride: nil, model: "gpt-4o-mini",
                                          timeout: 30,
                                          openAIBaseURL: "http://localhost:11434/v1",
                                          openAIAPIKey: "k", jsonMode: false,
                                          transport: transport)
        XCTAssertEqual(out, "Hello there")
        XCTAssertEqual(transport.requests.count, 1)
    }

    // AC-ERR-01 end-to-end (401 → readable auth error surfaces from `run`).
    func test_run_propagates401_asReadableError() async throws {
        let transport = RecordingTransport()
        transport.cannedResponse = response(
            status: 401,
            body: #"{"error":{"message":"Invalid API key","type":"invalid_request_error"}}"#)
        do {
            _ = try await LLMRunner.run(tool: .openaiCompatible,
                                        prompt: "x", transcript: "t",
                                        executablePathOverride: nil, model: "m",
                                        timeout: 30,
                                        openAIBaseURL: "http://localhost:11434/v1",
                                        openAIAPIKey: "bad", jsonMode: false,
                                        transport: transport)
            XCTFail("expected auth error")
        } catch let e as OpenAIRequestError {
            XCTAssertEqual(e, .auth("Invalid API key"))
            XCTAssertTrue((e.errorDescription ?? "").contains("401"))
        } catch {
            XCTFail("expected OpenAIRequestError.auth, got \(error)")
        }
    }

    // AC-REQ-08 — CLI-only params are absent from the HTTP request.
    func test_makeRequest_ignoresExecutablePathOverrideAndExtraArgs() async throws {
        let transport = RecordingTransport()
        transport.cannedResponse = response(
            status: 200,
            body: #"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#)
        _ = try await LLMRunner.run(tool: .openaiCompatible,
                                    prompt: "p", transcript: "t",
                                    executablePathOverride: "/usr/local/bin/claude",
                                    model: "m", extraArgs: ["--model", "bogus"],
                                    timeout: 30,
                                    openAIBaseURL: "http://localhost:11434/v1",
                                    openAIAPIKey: "k", jsonMode: false,
                                    transport: transport)
        let req = try XCTUnwrap(transport.requests.first)
        let url = req.url?.absoluteString ?? ""
        XCTAssertFalse(url.contains("claude"))
        XCTAssertFalse(url.contains("bogus"))
        // Body must not mention the extra arg either.
        let bodyStr = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(bodyStr.contains("bogus"))
    }

    // AC-CANCEL-01.
    func test_cancel_abortsRequestAndThrowsCancelled() async throws {
        let transport = RecordingTransport()
        transport.hangUntilCancelled = true
        let task = Task<String, Error> {
            try await LLMRunner.run(tool: .openaiCompatible,
                                    prompt: "p", transcript: "t",
                                    executablePathOverride: nil, model: "m",
                                    timeout: 30,
                                    openAIBaseURL: "http://localhost:11434/v1",
                                    openAIAPIKey: "k", jsonMode: false,
                                    transport: transport)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected LLMRunnerError.cancelled")
        } catch LLMRunnerError.cancelled {
            // pass
        } catch {
            XCTFail("expected .cancelled, got \(error)")
        }
        XCTAssertEqual(transport.requests.count, 1,
                       "the request was dispatched before cancellation aborted it")
    }

    /// AC-CANCEL — a cooperative `CancellationError` (e.g. a custom/test
    /// transport that throws it, rather than `URLSession`'s `URLError(.cancelled)`)
    /// must map to `LLMRunnerError.cancelled`, not `.launchFailed` (CodeRabbit #2).
    func test_runOpenAICompatible_mapsCancellationError_toCancelled() async throws {
        struct CancelTransport: OpenAITransport {
            func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
                throw CancellationError()
            }
        }
        do {
            _ = try await LLMRunner.run(tool: .openaiCompatible,
                                        prompt: "p", transcript: "t",
                                        executablePathOverride: nil, model: "m",
                                        timeout: 30,
                                        openAIBaseURL: "http://localhost:11434/v1",
                                        openAIAPIKey: "k", jsonMode: false,
                                        transport: CancelTransport())
            XCTFail("expected LLMRunnerError.cancelled")
        } catch LLMRunnerError.cancelled {
            // pass
        } catch {
            XCTFail("expected .cancelled, got \(error)")
        }
    }

    // AC-CANCEL-02 — cancel wins over a response that arrives just after.
    func test_cancel_winsOverLateResponse() async throws {
        let transport = RecordingTransport()
        transport.hangUntilCancelled = true
        transport.cannedResponse = response(
            status: 200,
            body: #"{"choices":[{"message":{"role":"assistant","content":"late"}}]}"#)
        let task = Task<String, Error> {
            try await LLMRunner.run(tool: .openaiCompatible,
                                    prompt: "p", transcript: "t",
                                    executablePathOverride: nil, model: "m",
                                    timeout: 30,
                                    openAIBaseURL: "http://localhost:11434/v1",
                                    openAIAPIKey: "k", jsonMode: false,
                                    transport: transport)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation to win")
        } catch LLMRunnerError.cancelled {
            // pass
        } catch {
            XCTFail("expected .cancelled, got \(error)")
        }
    }

    // AC-TIMEOUT-01/02 — transport-level timeout maps to the CLI error format.
    func test_timeout_throwsTimedOutWithSeconds() async throws {
        let transport = RecordingTransport()
        transport.cannedError = URLError(.timedOut)
        do {
            _ = try await LLMRunner.run(tool: .openaiCompatible,
                                        prompt: "p", transcript: "t",
                                        executablePathOverride: nil, model: "m",
                                        timeout: 45,
                                        openAIBaseURL: "http://localhost:11434/v1",
                                        openAIAPIKey: "k", jsonMode: false,
                                        transport: transport)
            XCTFail("expected timedOut")
        } catch LLMRunnerError.timedOut(let seconds) {
            // CLI path rounds up; the HTTP branch must match.
            XCTAssertEqual(seconds, 45)
        } catch {
            XCTFail("expected .timedOut(45), got \(error)")
        }
    }
}

// MARK: - Phase 7: diagnose HTTP branch + LLMTestResult extension

@MainActor
final class OpenAIDiagnoseTests: XCTestCase {

    private func http(_ status: Int, _ body: String) -> (HTTPURLResponse, Data) {
        let url = URL(string: "http://localhost:11434/v1/chat/completions")!
        return (HTTPURLResponse(url: url, statusCode: status,
                                httpVersion: nil, headerFields: nil)!,
                Data(body.utf8))
    }

    // AC-DIAG-01 — the new diagnostic fields exist and round-trip.
    func test_LLMTestResult_hasURLHTTPStatusRequestBodyFields() {
        var result = LLMTestResult()
        result.url = "http://localhost:11434/v1/chat/completions"
        result.httpStatus = 200
        result.requestBody = #"{"model":"m"}"#
        XCTAssertEqual(result.url, "http://localhost:11434/v1/chat/completions")
        XCTAssertEqual(result.httpStatus, 200)
        XCTAssertEqual(result.requestBody, #"{"model":"m"}"#)
        XCTAssertNil(result.exitCode, "HTTP results never carry an exit code")
    }

    // AC-DIAG-02.
    func test_diagnose_populatesURLAndRequestBody_forOpenAI() async {
        let transport = RecordingTransport()
        transport.cannedResponse = http(
            200, #"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#)
        let result = await LLMRunner.diagnose(
            tool: .openaiCompatible, prompt: "p", transcript: "t",
            executablePathOverride: nil, model: "gpt-4o-mini", timeout: 30,
            openAIBaseURL: "http://localhost:11434/v1", openAIAPIKey: "k",
            jsonMode: false, transport: transport)
        XCTAssertTrue(result.url.contains("chat/completions"))
        XCTAssertTrue(result.requestBody.contains("gpt-4o-mini"))
        XCTAssertEqual(result.httpStatus, 200)
    }

    // AC-DIAG-03.
    func test_diagnose_succeeded_trueOnlyFor2xxWithContent() async {
        let good = RecordingTransport()
        good.cannedResponse = http(
            200, #"{"choices":[{"message":{"role":"assistant","content":"ok"}}]}"#)
        let r1 = await LLMRunner.diagnose(tool: .openaiCompatible, prompt: "p",
            transcript: "t", executablePathOverride: nil, model: "m", timeout: 30,
            openAIBaseURL: "http://localhost:11434/v1", openAIAPIKey: "k",
            jsonMode: false, transport: good)
        XCTAssertTrue(r1.succeeded, "2xx with content ⇒ succeeded")

        let empty = RecordingTransport()
        empty.cannedResponse = http(200, #"{"choices":[]}"#)
        let r2 = await LLMRunner.diagnose(tool: .openaiCompatible, prompt: "p",
            transcript: "t", executablePathOverride: nil, model: "m", timeout: 30,
            openAIBaseURL: "http://localhost:11434/v1", openAIAPIKey: "k",
            jsonMode: false, transport: empty)
        XCTAssertFalse(r2.succeeded, "2xx with no content ⇒ not succeeded")

        let serverErr = RecordingTransport()
        serverErr.cannedResponse = http(500, #"{"error":{"message":"boom"}}"#)
        let r3 = await LLMRunner.diagnose(tool: .openaiCompatible, prompt: "p",
            transcript: "t", executablePathOverride: nil, model: "m", timeout: 30,
            openAIBaseURL: "http://localhost:11434/v1", openAIAPIKey: "k",
            jsonMode: false, transport: serverErr)
        XCTAssertFalse(r3.succeeded, "5xx ⇒ not succeeded")
    }

    // AC-DIAG-04 — httpStatus is the "did it run?" signal, not exitCode.
    func test_diagnose_httpStatusNotNil_isTheDidRunSignal_notExitCode() async {
        let transport = RecordingTransport()
        transport.cannedResponse = http(
            200, #"{"choices":[{"message":{"role":"assistant","content":"x"}}]}"#)
        let result = await LLMRunner.diagnose(
            tool: .openaiCompatible, prompt: "p", transcript: "t",
            executablePathOverride: nil, model: "m", timeout: 30,
            openAIBaseURL: "http://localhost:11434/v1", openAIAPIKey: "k",
            jsonMode: false, transport: transport)
        XCTAssertEqual(result.httpStatus, 200)
        XCTAssertNil(result.exitCode)
        XCTAssertTrue(result.didLaunch,
                      "didLaunch must be true when httpStatus is set")
    }

    // AC-DIAG-05 — runTest routes .openaiCompatible through the HTTP branch
    // (no executable path needed). Hits a refused localhost port so it fails
    // fast at the transport layer — the assertion is that it did NOT fail at
    // CLI resolution (no "find on PATH" / executableNotFound wording) and that
    // the request URL was populated.
    func test_runTest_routesOpenAIWithoutExecutablePath() async throws {
        let suite = UserDefaults(
            suiteName: "OpenAIDiagnoseTests.\(#function)")!
        suite.removePersistentDomain(
            forName: "OpenAIDiagnoseTests.\(#function)")
        let key = "OpenAIDiagnoseTests.\(#function).apiKey"
        KeychainHelper.delete(key: key)
        defer { KeychainHelper.delete(key: key) }

        let llm = LLMSettings(defaults: suite, apiKeyKeychainKey: key)
        llm.tool = .openaiCompatible
        llm.openAIBaseURL = "http://127.0.0.1:1/v1"   // nothing listening → refused
        llm.openAIModelName = "m"
        llm.openAIAPIKey = "k"
        llm.cliTimeout = 2                              // bound the failure

        await llm.runTest()
        let result = try XCTUnwrap(llm.lastTestResult)
        XCTAssertTrue(result.url.contains("chat/completions"),
                      "runTest must build an HTTP request for .openaiCompatible")
        let setup = result.setupError ?? ""
        XCTAssertFalse(setup.contains("find"),
                       "must not route through CLI executable resolution: \(setup)")
        XCTAssertFalse(setup.contains("PATH"),
                       "must not route through CLI executable resolution: \(setup)")
    }

    // AC-DIAG-02 — transport failure surfaces as setupError, no httpStatus.
    func test_diagnose_setupError_onTransportFailure() async {
        let transport = RecordingTransport()
        transport.cannedError = URLError(.cannotConnectToHost)
        let result = await LLMRunner.diagnose(
            tool: .openaiCompatible, prompt: "p", transcript: "t",
            executablePathOverride: nil, model: "m", timeout: 30,
            openAIBaseURL: "http://localhost:11434/v1", openAIAPIKey: "k",
            jsonMode: false, transport: transport)
        XCTAssertNotNil(result.setupError)
        XCTAssertNil(result.httpStatus)
        XCTAssertFalse(result.didLaunch)
    }
}

// MARK: - Phase 8: UI predicates + host-locality helper

@MainActor
final class OpenAIUIPredicateTests: XCTestCase {

    private func makeSettings() -> LLMSettings {
        let suite = UserDefaults(suiteName: "OpenAIUIPredicateTests.\(UUID().uuidString)")!
        return LLMSettings(defaults: suite,
                           apiKeyKeychainKey: "OpenAIUIPredicateTests.dummy.key")
    }

    // AC-UI-01/02 — the predicate that gates the CLI-only fields.
    func test_openAIFieldsHidden_forClaudeCursorNone() {
        let llm = makeSettings()
        llm.tool = .claude
        XCTAssertFalse(llm.isOpenAICompatible, "CLI fields shown for .claude")
        llm.tool = .cursor
        XCTAssertFalse(llm.isOpenAICompatible, "CLI fields shown for .cursor")
        llm.tool = .none
        XCTAssertFalse(llm.isOpenAICompatible, "CLI fields shown for .none")
    }

    func test_openAIFieldsVisible_forOpenAICompatible() {
        let llm = makeSettings()
        llm.tool = .openaiCompatible
        XCTAssertTrue(llm.isOpenAICompatible,
                      "CLI fields hidden + OpenAI fields shown for .openaiCompatible")
    }

    // AC-UI-04 — the timeout section label drops "CLI" for OpenAI.
    func test_timeoutLabel_isTimeoutNotCLI_forOpenAI() {
        let llm = makeSettings()
        llm.tool = .claude
        XCTAssertEqual(llm.timeoutLabel, "CLI timeout")
        llm.tool = .openaiCompatible
        XCTAssertEqual(llm.timeoutLabel, "Timeout")
    }
}

final class OpenAILocalityTests: XCTestCase {

    // AC-UI-03 — privacy disclaimer shows iff the base URL host is non-local.
    func test_isLocal_trueForLocalhostVariants() {
        XCTAssertTrue(OpenAILocality.isLocal(baseURL: "http://localhost:11434/v1"))
        XCTAssertTrue(OpenAILocality.isLocal(baseURL: "http://127.0.0.1:11434/v1"))
        XCTAssertTrue(OpenAILocality.isLocal(baseURL: "http://0.0.0.0:11434/v1"))
        XCTAssertTrue(OpenAILocality.isLocal(baseURL: "http://[::1]:11434/v1"))
        XCTAssertTrue(OpenAILocality.isLocal(baseURL: "http://myllama.local/v1"))
    }

    func test_isLocal_falseForRemoteHosts() {
        XCTAssertFalse(OpenAILocality.isLocal(baseURL: "https://api.openai.com/v1"))
        XCTAssertFalse(OpenAILocality.isLocal(baseURL: "https://api.groq.com/openai/v1"))
        XCTAssertFalse(OpenAILocality.isLocal(baseURL: "https://openrouter.ai/api/v1"))
    }

    func test_isLocal_falseForGarbageURL() {
        // Unparseable base URL must NOT be treated as local (safer to warn).
        XCTAssertFalse(OpenAILocality.isLocal(baseURL: ""))
        XCTAssertFalse(OpenAILocality.isLocal(baseURL: "not a url"))
    }
}

// MARK: - Phase 9 — Live AI local/remote split (Option C)

/// Validates the Live AI local/remote gate for `.openaiCompatible`
/// (Phase 9, Option C). Local OpenAI endpoints run the existing stateless
/// `kick()` branch — full transcript + current state each tick, JSON mode,
/// low temperature. Remote OpenAI endpoints disable Live AI entirely at the
/// `scheduleKick`/`kick` defense guards (and at the `aiActive` sites in
/// production, covered by `OpenAIUIPredicateTests`-style wiring).
///
/// Behavioural tests drive the REAL `feed → scheduleKick → kick` path with a
/// stubbed `performCall` that records the `LLMCall`, an injected `nowProvider`,
/// and `llmMinIntervalSeconds = 0` so kicks fire immediately.
@MainActor
final class OpenAILiveAISplitTests: XCTestCase {

    // MARK: - Helpers

    private final class TestClock {
        var now: Date
        init(_ start: Date) { now = start }
    }

    /// Records each stubbed LLM call so tests can inspect the `LLMCall` the
    /// session built (session mode, jsonMode, temperature, transcript, model,
    /// base URL) without spawning a subprocess or hitting the network.
    private final class CallLog {
        var calls: [LiveAISession.LLMCall] = []
    }

    /// Build a Live AI session backed by an `.openaiCompatible` LLMSettings
    /// with the given base URL. `apiKeyKeychainKey` is isolated per test so
    /// setting `openAIAPIKey` never clobbers the real app's Keychain item.
    private func makeSession(baseURL: String,
                             clock: TestClock,
                             log: CallLog,
                             suite: String) -> LiveAISession {
        UserDefaults().removePersistentDomain(forName: "\(suite).llm")
        UserDefaults().removePersistentDomain(forName: "\(suite).live")
        let llm = LLMSettings(defaults: UserDefaults(suiteName: "\(suite).llm")!,
                              apiKeyKeychainKey: "\(suite).apiKey")
        llm.tool = .openaiCompatible
        llm.openAIBaseURL = baseURL
        llm.openAIModelName = "test-model"
        llm.openAIAPIKey = ""   // local endpoints don't require a key
        let live = LiveAISettings(defaults: UserDefaults(suiteName: "\(suite).live")!)
        live.enabled = true
        live.llmMinIntervalSeconds = 0   // fire immediately

        let session = LiveAISession(llmSettings: llm, liveAISettings: live)
        session.nowProvider = { clock.now }
        session.performCall = { call in
            log.calls.append(call)
            // Minimal valid envelope so the success path runs.
            return #"{"summary":"ok","items":[]}"#
        }
        session.start()   // .openaiCompatible → sessionID nil → stateless
        return session
    }

    private func waitUntilIdle(_ session: LiveAISession,
                               timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while session.isThinking && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        }
    }

    // MARK: - AC-LIVEAI-01 / AC-LIVEAI-03 — local ⇒ stateless, full transcript

    func test_liveAI_localBaseURL_runsStateless_fullTranscriptEachTick() async {
        let clock = TestClock(Date())
        let log = CallLog()
        let session = makeSession(baseURL: "http://localhost:11434/v1",
                                  clock: clock, log: log,
                                  suite: "OpenAILiveAISplit.local")

        session.feed(transcript: "segment one", immediate: true)
        await waitUntilIdle(session)
        session.feed(transcript: "segment one segment two", immediate: true)
        await waitUntilIdle(session)

        // Two ticks fired (one per feed).
        XCTAssertGreaterThanOrEqual(log.calls.count, 2)
        // Stateless: the second tick ships the FULL latest transcript, not a
        // delta — so it must contain both segments. Guard rather than `last!`
        // — `XCTAssertGreaterThanOrEqual` doesn't halt execution, so a failed
        // count assertion would otherwise trap on the force-unwrap. (CodeRabbit #5.)
        guard let second = log.calls.last else {
            XCTFail("expected at least one tick call, got \(log.calls.count)")
            return
        }
        XCTAssertTrue(second.transcript.contains("segment one"))
        XCTAssertTrue(second.transcript.contains("segment two"))
        // LLMSession is always `.none` on the OpenAI HTTP path.
        XCTAssertEqual(second.session, .none)
    }

    // MARK: - AC-LIVEAI-02 — remote ⇒ disabled, no run called

    func test_liveAI_remoteBaseURL_isDisabled_noRunCalled() async {
        let clock = TestClock(Date())
        let log = CallLog()
        let session = makeSession(baseURL: "https://api.openai.com/v1",
                                  clock: clock, log: log,
                                  suite: "OpenAILiveAISplit.remote")

        session.feed(transcript: "hello world", immediate: true)
        await waitUntilIdle(session)

        XCTAssertEqual(log.calls.count, 0,
                       "Remote OpenAI base URL must disable Live AI — no tick fired.")
    }

    // MARK: - AC-LIVEAI-04 — JSON mode + low temperature for envelope reliability

    func test_liveAI_openAICompatible_requestsJSONModeAndLowTemp() async {
        let clock = TestClock(Date())
        let log = CallLog()
        let session = makeSession(baseURL: "http://localhost:11434/v1",
                                  clock: clock, log: log,
                                  suite: "OpenAILiveAISplit.jsonmode")

        session.feed(transcript: "hello world", immediate: true)
        await waitUntilIdle(session)

        XCTAssertEqual(log.calls.count, 1)
        XCTAssertTrue(log.calls[0].jsonMode,
                      "Live AI OpenAI ticks must request JSON mode for reliable envelopes.")
        XCTAssertEqual(log.calls[0].temperature, 0.2,
                       "Live AI OpenAI ticks must use a low temperature (0.2) for stable output.")
        // The OpenAI config is threaded from llmSettings into the LLMCall.
        XCTAssertEqual(log.calls[0].openAIBaseURL, "http://localhost:11434/v1")
        XCTAssertEqual(log.calls[0].model, "test-model")
    }

    // MARK: - AC-LIVEAI-05 — parser tolerates ```json fences from local models

    func test_parseEnvelope_handlesFencedJSONFromLocalModel() {
        // Local models often wrap JSON in ```json fences. parseEnvelope
        // extracts the first balanced JSON object regardless of fences.
        let fenced = """
        Here is the result:
        ```json
        {"summary":"team sync","items":[]}
        ```
        """
        let parsed = LiveAISession.parseEnvelope(from: fenced)
        XCTAssertEqual(parsed.summary, "team sync")
        XCTAssertEqual(parsed.items.count, 0)
    }
}