import XCTest
@testable import Mila

/// Guards the upgrade path for **Settings → AI Provider** and
/// **Settings → AI Features**.
///
/// Those two tabs replace what used to be two *different* tabs ("LLM" and
/// "Live AI"): connection config on one screen, the feature switches people
/// actually revisit on the other. That is a pure UI reorganisation — but the
/// two settings models it drives (`LLMSettings`, `LiveAISettings`) persist to
/// `UserDefaults` under namespaced string keys, and renaming or re-scoping any
/// of them would silently reset an upgrading user's provider, prompts and
/// toggles back to defaults with no error and nothing to roll back.
///
/// These tests pin the wire format: every key the AI tab writes is asserted
/// by its literal string, in both directions (a value already on disk is
/// adopted at init; an edit in the UI writes that same key). A rename shows
/// up here as a failure rather than as a bug report from a user who lost
/// their configuration.
///
/// Note the deliberate cross-model sharing: the output-language picker and
/// the automatic-summary prompt both sit on **AI Features** but are backed by
/// `liveAI.outputLanguage` and `liveAI.summaryPrompt`, because
/// `RecordingSummarizer` and `LiveAISession` have always read them from
/// `LiveAISettings`. Moving the control did not move the key.
@MainActor
final class AISettingsKeyCompatibilityTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    /// Isolated Keychain item so constructing an OpenAI-configured
    /// `LLMSettings` never reads or writes the real app's stored token.
    private var keychainKey: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "AISettingsKeyCompatibilityTests.\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
        keychainKey = "AISettingsKeyCompatibilityTests.\(UUID())"
    }

    override func tearDown() async throws {
        if let suiteName { defaults.removePersistentDomain(forName: suiteName) }
        try await super.tearDown()
    }

    private func makeLLM() -> LLMSettings {
        LLMSettings(defaults: defaults, apiKeyKeychainKey: keychainKey)
    }

    // MARK: - Provider section (shared by every AI feature)

    func test_provider_keys_are_adopted_from_existing_defaults() {
        // Simulate a user who configured the old, separate "LLM" tab.
        defaults.set("cursor", forKey: "llm.tool")
        defaults.set("/opt/homebrew/bin/cursor-agent", forKey: "llm.executablePath")
        defaults.set("--model sonnet", forKey: "llm.extraArgs")
        defaults.set(600.0, forKey: "llm.cli.timeout")

        let llm = makeLLM()

        XCTAssertEqual(llm.tool, .cursor)
        XCTAssertEqual(llm.executablePath, "/opt/homebrew/bin/cursor-agent")
        XCTAssertEqual(llm.extraArgs, "--model sonnet")
        XCTAssertEqual(llm.cliTimeout, 600.0)
    }

    func test_provider_edits_write_the_documented_keys() {
        let llm = makeLLM()

        llm.tool = .claude
        llm.executablePath = "/usr/local/bin/claude"
        llm.extraArgs = "--verbose"
        llm.cliTimeout = 120

        XCTAssertEqual(defaults.string(forKey: "llm.tool"), "claude")
        XCTAssertEqual(defaults.string(forKey: "llm.executablePath"), "/usr/local/bin/claude")
        XCTAssertEqual(defaults.string(forKey: "llm.extraArgs"), "--verbose")
        XCTAssertEqual(defaults.double(forKey: "llm.cli.timeout"), 120)
    }

    func test_openAI_endpoint_keys_round_trip() {
        defaults.set("groq", forKey: "llm.openai.provider")
        defaults.set("https://api.groq.com/openai/v1", forKey: "llm.openai.baseURL")
        defaults.set("llama-3.3-70b-versatile", forKey: "llm.openai.modelName")

        let llm = makeLLM()
        XCTAssertEqual(llm.openAIProvider, .groq)
        XCTAssertEqual(llm.openAIBaseURL, "https://api.groq.com/openai/v1")
        XCTAssertEqual(llm.openAIModelName, "llama-3.3-70b-versatile")

        llm.openAIProvider = .deepseek
        llm.openAIBaseURL = "https://api.deepseek.com/v1"
        llm.openAIModelName = "deepseek-chat"

        XCTAssertEqual(defaults.string(forKey: "llm.openai.provider"), "deepseek")
        XCTAssertEqual(defaults.string(forKey: "llm.openai.baseURL"), "https://api.deepseek.com/v1")
        XCTAssertEqual(defaults.string(forKey: "llm.openai.modelName"), "deepseek-chat")
    }

    // MARK: - Per-feature sections

    func test_feature_toggles_and_prompts_round_trip() {
        defaults.set(true, forKey: "llm.name.enabled")
        defaults.set("Give me a title", forKey: "llm.name.prompt")
        defaults.set(true, forKey: "llm.action.enabled")
        defaults.set("Email this to the team", forKey: "llm.action.prompt")
        defaults.set(false, forKey: "llm.summary.enabled")

        let llm = makeLLM()
        XCTAssertTrue(llm.nameGenerationEnabled)
        XCTAssertEqual(llm.namePrompt, "Give me a title")
        XCTAssertTrue(llm.postActionEnabled)
        XCTAssertEqual(llm.postActionPrompt, "Email this to the team")
        XCTAssertFalse(llm.summaryEnabled,
                       "An explicit opt-out of automatic summaries must survive the tab merge")

        llm.namePrompt = "Three words only"
        llm.postActionPrompt = "Translate to English"
        llm.summaryEnabled = true

        XCTAssertEqual(defaults.string(forKey: "llm.name.prompt"), "Three words only")
        XCTAssertEqual(defaults.string(forKey: "llm.action.prompt"), "Translate to English")
        XCTAssertTrue(defaults.bool(forKey: "llm.summary.enabled"))
    }

    // MARK: - Controls the merge moved between sections

    func test_outputLanguage_still_uses_the_liveAI_key() {
        // Sits at the top of AI Features now — it governs generated content,
        // not the connection, and drives BOTH the automatic summary and the
        // Live AI loop. Still persisted where it always was.
        defaults.set("he", forKey: "liveAI.outputLanguage")
        XCTAssertEqual(LiveAISettings(defaults: defaults).outputLanguage, .hebrew)

        let live = LiveAISettings(defaults: defaults)
        live.outputLanguage = .english
        XCTAssertEqual(defaults.string(forKey: "liveAI.outputLanguage"), "en")
    }

    func test_summaryPrompt_still_uses_the_liveAI_key() {
        // Newly editable from the "Automatic summary" section; the key is the
        // one `RecordingSummarizer` has always read.
        defaults.set("Summarize in one line", forKey: "liveAI.summaryPrompt")
        XCTAssertEqual(LiveAISettings(defaults: defaults).summaryPrompt,
                       "Summarize in one line")

        let live = LiveAISettings(defaults: defaults)
        live.summaryPrompt = "Bullet points only"
        XCTAssertEqual(defaults.string(forKey: "liveAI.summaryPrompt"), "Bullet points only")
    }

    func test_liveAI_section_keys_round_trip() {
        defaults.set(false, forKey: "liveAI.enabled")
        defaults.set("claude-haiku-4-5", forKey: "liveAI.model")
        defaults.set("Custom live prompt", forKey: "liveAI.prompt")
        defaults.set(true, forKey: "liveAI.backgroundMode")

        let live = LiveAISettings(defaults: defaults)
        XCTAssertFalse(live.enabled)
        XCTAssertEqual(live.model, "claude-haiku-4-5")
        XCTAssertEqual(live.prompt, "Custom live prompt")
        XCTAssertTrue(live.backgroundMode)

        live.enabled = true
        live.prompt = "Another prompt"
        XCTAssertTrue(defaults.bool(forKey: "liveAI.enabled"))
        XCTAssertEqual(defaults.string(forKey: "liveAI.prompt"), "Another prompt")
    }

    // MARK: - Tab identity

    func test_ai_tabs_replace_both_former_tabs() {
        // Two AI destinations — provider config and feature switches — each
        // distinct from the other and from their neighbours. Deep links
        // (`SettingsNavigation.pendingTab`) must resolve to exactly one tag.
        XCTAssertNotEqual(SettingsTab.aiProvider, SettingsTab.aiFeatures)
        XCTAssertNotEqual(SettingsTab.aiProvider, SettingsTab.models)
        XCTAssertNotEqual(SettingsTab.aiFeatures, SettingsTab.speakers)

        // Every tab tag is unique. The enum is `Int`-raw-valued and the split
        // inserted a case mid-list, so a hand-written raw value colliding with
        // a neighbour would silently make two tabs share a tag.
        let all: [SettingsTab] = [.general, .audio, .models, .aiProvider, .aiFeatures,
                                  .speakers, .meetings, .voiceMemos, .storage]
        XCTAssertEqual(Set(all).count, all.count, "Two Settings tabs share a tag")
    }

    // MARK: - Controls the two-tab split moved between screens

    func test_timeout_default_matches_the_reset_button() {
        // Settings → AI Provider's "Reset" writes `LLMSettings.defaultTimeout`.
        // If that drifted from the value used when nothing is persisted, Reset
        // would quietly move users to a different timeout than a fresh install.
        XCTAssertEqual(makeLLM().cliTimeout, LLMSettings.defaultTimeout)
        XCTAssertEqual(LLMSettings.defaultTimeout, 300)

        // And it still round-trips through the documented key.
        let llm = makeLLM()
        llm.cliTimeout = 450
        XCTAssertEqual(defaults.double(forKey: "llm.cli.timeout"), 450)
    }

    func test_feature_switches_moved_to_row_headers_keep_their_keys() {
        // The four AI Features rows each expose a real `Toggle` in the row
        // header instead of an On/Off label plus a switch hidden one
        // disclosure down. Same four keys behind them.
        let llm = makeLLM()
        llm.summaryEnabled = true
        llm.nameGenerationEnabled = true
        llm.postActionEnabled = true

        XCTAssertTrue(defaults.bool(forKey: "llm.summary.enabled"))
        XCTAssertTrue(defaults.bool(forKey: "llm.name.enabled"))
        XCTAssertTrue(defaults.bool(forKey: "llm.action.enabled"))

        let live = LiveAISettings(defaults: defaults)
        live.enabled = true
        XCTAssertTrue(defaults.bool(forKey: "liveAI.enabled"))
    }
}
