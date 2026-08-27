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

        // Pin the raw values. Asserting the cases are merely *distinct* would
        // be vacuous — `Hashable` is synthesized over the cases, so they never
        // collide whatever their raw values, and Swift rejects duplicate
        // explicit raw values at compile time. What the split actually risks
        // is SHIFTING the implicit raw value of every case after the insertion
        // point. Nothing persists them today (`SettingsNavigation.pendingTab`
        // is in-memory only, which is why this PR could renumber freely), so
        // this is a tripwire for whoever first writes one to disk or a URL.
        //
        // The list is also the authoritative destination inventory. Since
        // #177 it is no longer capped: destinations are sidebar rows, so a
        // tenth costs scrollable vertical space rather than a re-measured tab
        // strip. Adding one here plus a case is the whole job.
        XCTAssertEqual(SettingsTab.general.rawValue, 0)
        XCTAssertEqual(SettingsTab.audio.rawValue, 1)
        XCTAssertEqual(SettingsTab.models.rawValue, 2)
        XCTAssertEqual(SettingsTab.aiProvider.rawValue, 3)
        XCTAssertEqual(SettingsTab.aiFeatures.rawValue, 4)
        XCTAssertEqual(SettingsTab.speakers.rawValue, 5)
        XCTAssertEqual(SettingsTab.meetings.rawValue, 6)
        XCTAssertEqual(SettingsTab.voiceMemos.rawValue, 7)
        XCTAssertEqual(SettingsTab.storage.rawValue, 8)
    }

    // MARK: - Sidebar destination inventory (#177)

    func test_every_settings_destination_is_presentable_in_the_sidebar() {
        // `SettingsView` builds the sidebar from `allCases` and switches the
        // detail pane on the same enum, so a case with no `switch` arm is a
        // compile error and a case missing from `allCases` is impossible.
        // What CAN silently break is the presentation: a destination with a
        // blank title is an unclickable-looking empty row, and a duplicate
        // title or identifier makes deep links and GUI tests ambiguous.
        let all = SettingsTab.allCases
        XCTAssertEqual(all.count, 9, "Destination count changed — intended?")

        for tab in all {
            XCTAssertFalse(tab.title.isEmpty, "\(tab) has no sidebar title")
            XCTAssertFalse(tab.systemImage.isEmpty, "\(tab) has no sidebar icon")
            XCTAssertTrue(tab.accessibilityID.hasPrefix("settings.section."),
                          "\(tab) identifier must stay namespaced — GUI tests match on it")
        }

        XCTAssertEqual(Set(all.map(\.title)).count, all.count,
                       "Two destinations share a sidebar title")
        XCTAssertEqual(Set(all.map(\.accessibilityID)).count, all.count,
                       "Two destinations share an accessibility identifier")
        XCTAssertEqual(Set(all.map(\.id)).count, all.count,
                       "Two destinations share a List identity")

        // Sidebar order is `allCases` order, which is declaration order,
        // which is raw-value order. The old left-to-right tab order is
        // preserved top-to-bottom.
        XCTAssertEqual(all.map(\.rawValue), Array(0..<all.count))
    }

    /// `MilaUITests` hardcode these strings — the UI-test target cannot
    /// import the app's types, so this is the only thing keeping the two
    /// sides in sync. `DetailLayoutUITests.settingsSections` drives every
    /// Settings assertion off them, and `SpeakerSelfHealUITests` clicks
    /// `settings.section.speakers` by name.
    func test_destination_identifiers_match_the_strings_the_gui_tests_use() {
        XCTAssertEqual(SettingsTab.general.accessibilityID, "settings.section.general")
        XCTAssertEqual(SettingsTab.audio.accessibilityID, "settings.section.audio")
        XCTAssertEqual(SettingsTab.models.accessibilityID, "settings.section.models")
        XCTAssertEqual(SettingsTab.aiProvider.accessibilityID, "settings.section.aiProvider")
        XCTAssertEqual(SettingsTab.aiFeatures.accessibilityID, "settings.section.aiFeatures")
        XCTAssertEqual(SettingsTab.speakers.accessibilityID, "settings.section.speakers")
        XCTAssertEqual(SettingsTab.meetings.accessibilityID, "settings.section.meetings")
        XCTAssertEqual(SettingsTab.voiceMemos.accessibilityID, "settings.section.voiceMemos")
        XCTAssertEqual(SettingsTab.storage.accessibilityID, "settings.section.storage")
    }

    /// The Settings window floor has to leave the destinations a workable
    /// content width. #194's post-mortem called this out specifically
    /// (Models and AI Provider are the widest), and a future tweak to the
    /// sidebar width or the inset could quietly eat into it.
    func test_settings_window_floor_leaves_room_for_the_widest_destination() {
        // 188 pt sidebar + 560 pt of content + 2 × 20 pt inset. Pinned as
        // literals on purpose: this is a tripwire, so shrinking the content
        // budget has to be a deliberate edit here rather than a side effect
        // of widening the sidebar.
        XCTAssertEqual(SettingsView.minWindowWidth, 788,
                       "Settings' narrowest window no longer leaves 560 pt of destination content")
        // 188 pt sidebar + the old fixed window's 700 pt of content + inset,
        // so first launch is not a downgrade from the tab strip.
        XCTAssertEqual(SettingsView.idealWindowWidth, 928,
                       "Settings' default window no longer offers the 700 pt of content the fixed window had")
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
