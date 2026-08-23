import Foundation
import Combine

/// A closed set of OpenAI-compatible `/v1/chat/completions` providers. Each
/// ships a base URL and a default model name so the Settings UI can offer
/// working one-click presets, with `.custom` for anything else that speaks
/// the same protocol.
///
/// There is deliberately **no** single hardcoded model fallback: every
/// non-custom preset carries its own `defaultModelName` (see AC-PRESET-06).
/// The locale-aware default-model mechanism in `ModelManager` applies to
/// Whisper *transcription* models only and is not reused here.
enum OpenAIProvider: String, CaseIterable, Identifiable, Codable {
    case ollamaLocal
    case ollamaCloud
    case openai
    case openrouter
    case groq
    case deepseek
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollamaLocal:  return "Ollama (local)"
        case .ollamaCloud:  return "Ollama Cloud"
        case .openai:       return "OpenAI"
        case .openrouter:   return "OpenRouter"
        case .groq:         return "Groq"
        case .deepseek:     return "DeepSeek"
        case .custom:       return "Custom"
        }
    }

    /// Base URL the client appends `chat/completions` to. Empty for `.custom`
    /// (the user supplies it).
    var baseURL: String {
        switch self {
        case .ollamaLocal:  return "http://localhost:11434/v1"
        case .ollamaCloud:  return "https://ollama.com/v1"
        case .openai:       return "https://api.openai.com/v1"
        case .openrouter:   return "https://openrouter.ai/api/v1"
        case .groq:         return "https://api.groq.com/openai/v1"
        case .deepseek:     return "https://api.deepseek.com/v1"
        case .custom:       return ""
        }
    }

    /// Whether the endpoint expects a Bearer token. A local Ollama server has
    /// no auth by default; every hosted provider does.
    var requiresAPIKey: Bool { self != .ollamaLocal }

    /// Per-preset default model name. Empty for `.custom` (user-supplied).
    var defaultModelName: String {
        switch self {
        case .ollamaLocal:  return "llama3.1"
        case .ollamaCloud:  return "llama3.1"
        case .openai:       return "gpt-4o-mini"
        case .openrouter:   return "openai/gpt-4o-mini"
        case .groq:         return "llama-3.3-70b-versatile"
        case .deepseek:     return "deepseek-chat"
        case .custom:       return ""
        }
    }
}

/// Which local LLM CLI Mila will shell out to for naming
/// recordings and running post-recording actions. We deliberately keep this
/// to a closed set of known CLIs so the Settings UI can show working
/// defaults + concrete examples — supporting arbitrary CLIs would force the
/// user to know shell-quoting rules.
enum LLMTool: String, CaseIterable, Identifiable, Codable {
    case none
    case claude
    case cursor
    case gemini
    case openaiCompatible = "openai_compatible"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:            return "Off"
        case .claude:          return "Claude (claude CLI)"
        case .cursor:          return "Cursor (cursor-agent CLI)"
        case .gemini:          return "Gemini (gemini CLI)"
        case .openaiCompatible: return "OpenAI Compatible"
        }
    }

    /// Whether this tool runs on the user's machine and can therefore open a
    /// file we name in the prompt. Gates `TranscriptDelivery.reference`
    /// (issue #179).
    ///
    /// True for all three CLIs: each is an agentic coding tool whose whole
    /// premise is reading the local filesystem, and each is launched with
    /// workspace trust already granted (`cursor-agent -f`, `gemini
    /// --skip-trust`) so a read in the sandbox cwd's world doesn't stall on a
    /// prompt Mila would never see.
    ///
    /// False for `.openaiCompatible` — a remote HTTP endpoint has no filesystem
    /// — and for `.none`, which runs nothing. This is the "must never apply to
    /// the OpenAI-compatible provider" constraint from #179, expressed once
    /// here so the Settings UI and `LLMRunner.effectiveDelivery` cannot drift
    /// apart on it.
    var readsLocalFiles: Bool {
        switch self {
        case .claude, .cursor, .gemini: return true
        case .none, .openaiCompatible:  return false
        }
    }

    /// Default executable name (looked up via the user's `$PATH`). Empty for
    /// `.openaiCompatible` — the HTTP branch in `LLMRunner.run` returns before
    /// `resolveExecutable` is ever reached for this case.
    var executableName: String {
        switch self {
        case .none:            return ""
        case .claude:          return "claude"
        case .cursor:          return "cursor-agent"
        case .gemini:          return "gemini"
        case .openaiCompatible: return ""
        }
    }

    /// Arguments for a one-shot, non-interactive print. Both `claude -p` and
    /// `cursor-agent -p` accept a prompt argument and stream the answer to
    /// stdout, exiting when done.
    ///
    /// `cursor-agent` also requires `-f` (force / trust the current working
    /// directory) in non-interactive mode — without it, the very first
    /// run bails with "Workspace Trust Required". We always pass it because
    /// the cwd is whatever launchd handed Mila, the user never
    /// sees it, and we're only asking the LLM to read a transcript.
    ///
    /// `model`, when non-empty, picks a specific model instead of the CLI's
    /// default — used by Live AI mode to pin a cheap model (Haiku) for
    /// the high-frequency action-item loop without changing the user's
    /// global CLI default.
    ///
    /// `session`, when non-`.none`, attaches the invocation to a named
    /// Claude conversation. Two modes:
    ///   * `.new(uuid)` → pass `--session-id <uuid>`; claude CREATES the
    ///     conversation. Reusing the same uuid later via `--session-id`
    ///     fails with "Session ID is already in use."
    ///   * `.resume(uuid)` → pass `--resume <uuid>`; claude continues
    ///     an existing conversation with all prior turns + responses in
    ///     scope.
    ///
    /// cursor-agent has no documented equivalent in `-p` mode and any
    /// session value is silently ignored for that tool.
    func arguments(prompt: String,
                   model: String? = nil,
                   session: LLMSession = .none) -> [String] {
        let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasModel = !(trimmedModel?.isEmpty ?? true)
        switch self {
        case .none:            return []
        case .openaiCompatible: return []   // HTTP path never spawns a process
        case .claude:
            var args: [String] = ["-p", prompt]
            if hasModel, let m = trimmedModel {
                args.append(contentsOf: ["--model", m])
            }
            switch session {
            case .none:
                break
            case .new(let id):
                args.append(contentsOf: ["--session-id", id.uuidString])
            case .resume(let id):
                args.append(contentsOf: ["--resume", id.uuidString])
            }
            return args
        case .cursor:
            var args: [String] = ["-p", "-f", prompt]
            if hasModel, let m = trimmedModel {
                args.append(contentsOf: ["--model", m])
            }
            // session intentionally ignored — see doc above.
            return args
        case .gemini:
            // `gemini -p <prompt>` runs one-shot and streams the answer to
            // stdout. `--skip-trust` is the gemini analogue of cursor's `-f`:
            // we always launch in an isolated, empty sandbox dir (for TCC
            // safety) which gemini treats as an untrusted workspace and
            // otherwise refuses to run in headless mode. `-m` pins a model
            // (e.g. gemini-2.5-flash); the CLI's configured default is used
            // when omitted.
            var args: [String] = ["-p", prompt, "--skip-trust"]
            if hasModel, let m = trimmedModel {
                args.append(contentsOf: ["-m", m])
            }
            // session intentionally ignored — gemini's -p mode has no
            // documented conversation-resume flag.
            return args
        }
    }
}

/// Stateful-conversation mode for the LLM CLI. See
/// `LLMTool.arguments(prompt:model:session:)`.
enum LLMSession: Equatable {
    case none
    case new(UUID)
    case resume(UUID)
}

/// User-configurable prompts + tool selection for the LLM integration. The
/// "name" prompt is sent right after a recording transcribes so the user can
/// accept / reject a suggested title; the "action" prompt is what the user
/// pipes their transcript into for things like "summarize and email this".
@MainActor
final class LLMSettings: ObservableObject {
    @Published var tool: LLMTool {
        didSet {
            guard tool != oldValue else { return }
            defaults.set(tool.rawValue, forKey: Keys.tool)
            // Defer the Keychain read until the user actually selects the
            // OpenAI tool — local/CLI-only users never trigger the macOS
            // Keychain prompt. Mirrors `RemoteTranscriptionSettings.backend`.
            if tool == .openaiCompatible { loadOpenAIAPIKeyIfNeeded() }
        }
    }

    /// Optional override of the CLI executable path. When empty we rely on
    /// the system `$PATH` — convenient on dev machines, less so for users
    /// who installed claude/cursor in a non-shell-default location (e.g.
    /// `~/.local/bin`).
    @Published var executablePath: String {
        didSet {
            guard executablePath != oldValue else { return }
            defaults.set(executablePath, forKey: Keys.executablePath)
        }
    }

    @Published var nameGenerationEnabled: Bool {
        didSet { defaults.set(nameGenerationEnabled, forKey: Keys.nameEnabled) }
    }

    @Published var namePrompt: String {
        didSet { defaults.set(namePrompt, forKey: Keys.namePrompt) }
    }

    @Published var postActionEnabled: Bool {
        didSet { defaults.set(postActionEnabled, forKey: Keys.actionEnabled) }
    }

    @Published var postActionPrompt: String {
        didSet { defaults.set(postActionPrompt, forKey: Keys.actionPrompt) }
    }

    /// Send-to-LLM action only: hand the CLI the recording's sidecar **paths**
    /// instead of pasting the transcript into the prompt (issue #179).
    ///
    /// Off by default, deliberately. Inlining is the shape that works
    /// everywhere, and reference delivery trades that for fidelity: the `.srt`
    /// it points at is the only artifact carrying timestamps, and the CLI can
    /// re-read and seek within a file it opened itself. The cost is a
    /// dependency on the CLI actually performing the read — which is why this
    /// governs the *action* and not title generation or the automatic summary.
    /// Those two run unattended on every recording, so a tool that declines to
    /// read the file would degrade them silently and permanently; the action is
    /// user-triggered and its result is shown in a banner, where "it didn't
    /// read the transcript" is immediately visible.
    ///
    /// Scoped per-feature rather than global for the same reason. See
    /// `actionDeliversTranscriptByPath` for the readiness gate that pairs with
    /// this switch (`.claude/rules/feature-gates.md`).
    @Published var actionTranscriptByPath: Bool {
        didSet {
            guard actionTranscriptByPath != oldValue else { return }
            defaults.set(actionTranscriptByPath, forKey: Keys.actionTranscriptByPath)
        }
    }

    /// "Enabled AND usable": the user asked for path delivery *and* the
    /// selected tool can actually read a local file. Per
    /// `.claude/rules/feature-gates.md` the persisted switch on its own is not
    /// a readiness signal — a user who turns this on and later switches to the
    /// OpenAI-compatible endpoint must not start shipping paths to a remote
    /// endpoint that cannot open them. Callers ask this, never
    /// `actionTranscriptByPath`.
    ///
    /// The stored preference is left untouched by the gate so switching back to
    /// a CLI restores the user's choice rather than silently losing it.
    var actionDeliversTranscriptByPath: Bool {
        actionTranscriptByPath && tool.readsLocalFiles
    }

    /// Value `cliTimeout` falls back to when nothing is persisted, and the
    /// value Settings → AI Provider's "Reset" restores. Named rather than
    /// repeated as a literal so the two can't drift apart.
    static let defaultTimeout: TimeInterval = 300

    /// Maximum wall-clock seconds Mila allows a post-recording LLM call to
    /// run before killing the subprocess. Applies to title generation, the
    /// auto-summary, and the Send-action button. Live AI's per-tick timeouts
    /// are tuned separately and are not affected by this setting.
    @Published var cliTimeout: TimeInterval {
        didSet {
            guard cliTimeout != oldValue else { return }
            defaults.set(cliTimeout, forKey: Keys.cliTimeout)
        }
    }

    /// Master switch for the AUTOMATIC post-recording summary
    /// (`RecordingSummarizer`). When off, no summary is generated when a
    /// recording finishes, on launch backfill, or on re-transcription —
    /// the app behaves as a transcript-only tool. The explicit
    /// "Regenerate summary" affordance still works on demand; this only
    /// governs the automatic path.
    ///
    /// Defaults to ON (see init) so existing users keep their summaries
    /// unless they opt out. Surfaced in the "Automatic summary" section of
    /// Settings → AI Features, alongside the summary prompt it governs.
    @Published var summaryEnabled: Bool {
        didSet { defaults.set(summaryEnabled, forKey: Keys.summaryEnabled) }
    }

    /// Free-text extra CLI arguments appended to EVERY post-recording
    /// invocation (title suggestion, auto-summary, Send-action) as well as the
    /// test panel run — lets the user pin a model or pass debug/permission
    /// flags without us baking in a picker. Tokenized shell-style before being
    /// passed to the CLI (see `extraArgsTokens`). Live AI is excluded: it pins
    /// its own model and would clash with a user-supplied `--model`.
    @Published var extraArgs: String {
        didSet {
            guard extraArgs != oldValue else { return }
            defaults.set(extraArgs, forKey: Keys.extraArgs)
        }
    }

    /// `extraArgs` parsed into an argv array, ready to hand to `LLMRunner`.
    var extraArgsTokens: [String] { LLMRunner.tokenizeArguments(extraArgs) }

    // MARK: - OpenAI-compatible endpoint

    /// Which OpenAI-compatible provider the user picked (drives the preset
    /// picker). Defaults to `.custom` so the base URL / model fields start
    /// empty and the user chooses a provider to fill them.
    @Published var openAIProvider: OpenAIProvider {
        didSet {
            guard openAIProvider != oldValue else { return }
            defaults.set(openAIProvider.rawValue, forKey: Keys.openAIProvider)
        }
    }

    @Published var openAIBaseURL: String {
        didSet {
            guard openAIBaseURL != oldValue else { return }
            defaults.set(openAIBaseURL, forKey: Keys.openAIBaseURL)
        }
    }

    @Published var openAIModelName: String {
        didSet {
            guard openAIModelName != oldValue else { return }
            defaults.set(openAIModelName, forKey: Keys.openAIModelName)
        }
    }

    /// Bearer token for the OpenAI-compatible endpoint. Stored in the
    /// **Keychain**, never `UserDefaults` — mirrors `RemoteTranscriptionSettings`
    /// verbatim: write-through on `didSet`, lazy restore via
    /// `loadOpenAIAPIKeyIfNeeded`, and an `isAdoptingStoredAPIKey` guard so
    /// adopting the stored value doesn't trigger a redundant Keychain write.
    @Published var openAIAPIKey: String {
        didSet {
            guard openAIAPIKey != oldValue else { return }
            guard !isAdoptingStoredAPIKey else { return }
            KeychainHelper.save(key: apiKeyKeychainKey, value: openAIAPIKey)
        }
    }

    /// Apply a provider preset: fills the base URL + model fields only when
    /// they are empty or still carry the *previous* preset's default, so a
    /// user's custom value survives a preset change. The provider itself is
    /// always updated (and persisted via `openAIProvider.didSet`).
    ///
    /// `previous` MUST be the provider value *before* this change. In the
    /// Settings UI the `Picker` binding updates `openAIProvider` to the new
    /// preset **before** `.onChange` fires, so `openAIProvider` is already
    /// the new value by the time this runs — re-reading it here would
    /// compare against the *new* preset and never overwrite the field, so
    /// switching OpenAI→Groq would leave the endpoint pointed at OpenAI.
    /// The Picker's `.onChange(old, new)` passes the real previous value
    /// explicitly (issue celarent7/mila#2).
    func applyPreset(_ newPreset: OpenAIProvider, previous: OpenAIProvider) {
        openAIProvider = newPreset
        if openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || openAIBaseURL == previous.baseURL {
            openAIBaseURL = newPreset.baseURL
        }
        if openAIModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || openAIModelName == previous.defaultModelName {
            openAIModelName = newPreset.defaultModelName
        }
    }

    /// Whether a blank API key makes the configured endpoint unusable, so
    /// `isConfigured` must report "not ready" rather than let auto-title /
    /// auto-summary fire requests that are guaranteed to come back 401.
    ///
    /// Mirrors `RemoteTranscriptionSettings.requiresAPIKey`: a *named hosted*
    /// preset (OpenAI, Groq, OpenRouter, DeepSeek, Ollama Cloud) always needs a
    /// token; a local server and a `.custom` endpoint do not — a self-hosted or
    /// LAN box is assumed open unless the user supplies one, and guessing
    /// otherwise would lock those users out of the feature entirely.
    static func requiresAPIKeyForReadiness(provider: OpenAIProvider,
                                           baseURL: String) -> Bool {
        switch provider {
        case .ollamaLocal, .custom:
            return false
        default:
            // A named preset repointed at localhost (e.g. a local proxy) is
            // local-server territory too — don't demand a key there either.
            return !OpenAILocality.isLocal(baseURL: baseURL)
        }
    }

    /// Convenience the UI uses to decide whether to surface the rename /
    /// run-action buttons at all. "Enabled AND ready" (per
    /// `.claude/rules/feature-gates.md`): the OpenAI tool needs a non-blank
    /// base URL AND a non-blank model name — without a model, auto-title/summary
    /// would launch HTTP requests guaranteed to fail (issue celarent7/mila#3/#4,
    /// CodeRabbit #3) — plus an API key whenever the selected provider is a
    /// named hosted one (see `requiresAPIKeyForReadiness`). Local/anonymous and
    /// `.custom` endpoints stay configured without a key. The CLI tools are
    /// ready as soon as they're selected.
    var isConfigured: Bool {
        switch tool {
        case .none:             return false
        case .openaiCompatible:
            let url = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = openAIModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty, !model.isEmpty else { return false }
            guard Self.requiresAPIKeyForReadiness(provider: openAIProvider,
                                                  baseURL: url) else { return true }
            return !openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:                return true
        }
    }

    /// True iff the OpenAI-compatible endpoint is the active tool. Drives the
    /// Settings UI's CLI-vs-HTTP field swap (AC-UI-01/02): CLI-only fields
    /// (executable path, extra args) render only when this is false.
    var isOpenAICompatible: Bool { tool == .openaiCompatible }

    /// Label for the timeout row. Drops the "CLI" qualifier for the OpenAI
    /// path, where the timeout bounds an HTTP request, not a process
    /// (AC-UI-04).
    var timeoutLabel: String { isOpenAICompatible ? "Timeout" : "CLI timeout" }

    /// True when Live AI must NOT run for this tool (Phase 9, Option C).
    /// Remote OpenAI-compatible endpoints re-bill the full transcript every
    /// stateless tick with no prompt-cache discount, so Live AI is gated to
    /// *local* endpoints only (localhost / loopback / `.local`). Local ones
    /// are free and run the existing stateless `kick()` branch. Reuses the
    /// Phase 8 `OpenAILocality.isLocal` host helper (same one the privacy
    /// disclaimer uses) rather than duplicating the classification.
    var liveAIDisabledByRemoteOpenAI: Bool {
        guard tool == .openaiCompatible else { return false }
        return !OpenAILocality.isLocal(baseURL: openAIBaseURL)
    }

    // MARK: - Test / diagnostics
    //
    // Backing state for the Settings → AI Provider "Test" panel. The transcript /
    // result here are an ephemeral scratch area for answering "why isn't my
    // LLM working?" — they're not persisted (the extra-args the test uses ARE
    // persisted; see `extraArgs` above). Kept on the app-lifetime settings
    // object (not view @State) so the result survives tab switches while the
    // Settings window is open.

    /// Which configured prompt the test runs.
    enum TestPromptKind: String, CaseIterable, Identifiable {
        case name
        case action
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name:   return "Name suggestion"
            case .action: return "Action"
            }
        }
    }

    @Published var testPromptKind: TestPromptKind = .name
    /// Editable transcript fed to the test run; prefilled with a short sample
    /// meeting so the button works on a fresh install with one click.
    @Published var testTranscript: String = LLMSettings.sampleTranscript
    @Published private(set) var isTesting = false
    @Published private(set) var lastTestResult: LLMTestResult?

    /// The prompt the test will actually send, given the current selection.
    var testPrompt: String {
        testPromptKind == .name ? namePrompt : postActionPrompt
    }

    /// Run the configured prompt against the sample transcript and stash the
    /// full result (command + streams + exit code) for the UI to render.
    func runTest() async {
        // A fast double-tap can enqueue two `Task { await runTest() }` calls
        // before the button re-renders disabled — bail on the second so we
        // don't spawn duplicate subprocesses or let a late finisher overwrite
        // a newer result.
        guard !isTesting else { return }
        isTesting = true
        lastTestResult = nil
        defer { isTesting = false }
        // Only the OpenAI path needs a model from settings (the CLIs pick their
        // own); passing `openAIModelName` here lets the test panel exercise the
        // exact endpoint+model the user configured without an executable path.
        let model: String? = (tool == .openaiCompatible)
            ? (openAIModelName.isEmpty ? nil : openAIModelName)
            : nil
        let result = await LLMRunner.diagnose(
            tool: tool,
            prompt: testPrompt,
            transcript: testTranscript,
            extraArgs: extraArgsTokens,
            executablePathOverride: executablePath.isEmpty ? nil : executablePath,
            model: model,
            // Use the same timeout real runs use so the test faithfully
            // reproduces production behaviour — including letting the user
            // confirm that raising the timeout fixes a slow agentic run.
            timeout: cliTimeout,
            openAIBaseURL: openAIBaseURL,
            openAIAPIKey: openAIAPIKey,
            jsonMode: false)
        lastTestResult = result
    }

    /// Sample meeting transcript used by the test panel. Deliberately short,
    /// concrete, and decision-laden so both "suggest a title" and "summarize"
    /// prompts have something real to chew on.
    static let sampleTranscript = """
        Alex: Thanks for joining. The goal today is to lock the Q3 launch date for the mobile app.
        Priya: Engineering is on track — the remaining blocker is the offline-sync bug, which I expect closed by Wednesday.
        Sam: Marketing needs two weeks of lead time once we have a firm date for the press push.
        Alex: Then let's target August 19th for launch, with a go/no-go check the Friday before.
        Priya: Works for me. I'll send the updated timeline today.
        Sam: I'll draft the announcement and share it for review by next Monday.
        Alex: Great — action items: Priya closes the sync bug and sends the timeline, Sam drafts the announcement. Let's reconvene Friday.
        """

    private let defaults: UserDefaults
    /// Keychain item the OpenAI API key is stored under. Injectable so tests
    /// never read/clobber the real app's item — mirrors
    /// `RemoteTranscriptionSettings.apiKeyKeychainKey`. Net-new param with a
    /// production-safe default (existing `MilaApp.init()` call site is
    /// unchanged).
    private let apiKeyKeychainKey: String
    private var hasLoadedOpenAIAPIKey = false
    private var isAdoptingStoredAPIKey = false

    init(defaults: UserDefaults = .standard,
         apiKeyKeychainKey: String = Keys.openAIAPIKey) {
        self.defaults = defaults
        self.apiKeyKeychainKey = apiKeyKeychainKey
        let rawTool = defaults.string(forKey: Keys.tool) ?? LLMTool.none.rawValue
        self.tool = LLMTool(rawValue: rawTool) ?? .none
        self.executablePath = defaults.string(forKey: Keys.executablePath) ?? ""
        self.nameGenerationEnabled = defaults.bool(forKey: Keys.nameEnabled)
        self.namePrompt = defaults.string(forKey: Keys.namePrompt) ?? Self.defaultNamePrompt
        self.postActionEnabled = defaults.bool(forKey: Keys.actionEnabled)
        self.postActionPrompt = defaults.string(forKey: Keys.actionPrompt) ?? Self.defaultActionPrompt
        // Default-OFF, so a plain `bool` read is the right one here (unlike
        // `summaryEnabled` below): "key absent" and "user said no" mean the
        // same thing, and inlining must stay the behaviour nobody opted into.
        self.actionTranscriptByPath = defaults.bool(forKey: Keys.actionTranscriptByPath)
        // Default-on: a bare `defaults.bool` would read false for users who
        // have never seen this key, silently disabling summaries for
        // everyone on upgrade. Treat "key absent" as true.
        self.summaryEnabled = (defaults.object(forKey: Keys.summaryEnabled) as? Bool) ?? true
        self.cliTimeout = (defaults.object(forKey: Keys.cliTimeout) as? Double) ?? Self.defaultTimeout
        self.extraArgs = defaults.string(forKey: Keys.extraArgs) ?? ""

        self.openAIProvider = OpenAIProvider(rawValue:
            defaults.string(forKey: Keys.openAIProvider) ?? "") ?? .custom
        self.openAIBaseURL = defaults.string(forKey: Keys.openAIBaseURL) ?? ""
        self.openAIModelName = defaults.string(forKey: Keys.openAIModelName) ?? ""
        // Start empty; defer the Keychain read until OpenAI is the active tool
        // (here if it's the restored choice, otherwise lazily in `tool.didSet`).
        self.openAIAPIKey = ""
        if tool == .openaiCompatible { loadOpenAIAPIKeyIfNeeded() }
    }

    /// Lazily read the OpenAI API key from the Keychain the first time the
    /// OpenAI tool becomes active. Idempotent (guarded by
    /// `hasLoadedOpenAIAPIKey`) and non-destructive: an in-progress user edit
    /// is kept rather than overwritten by the stored value.
    private func loadOpenAIAPIKeyIfNeeded() {
        guard !hasLoadedOpenAIAPIKey else { return }
        hasLoadedOpenAIAPIKey = true
        guard openAIAPIKey.isEmpty else { return }
        guard let stored = KeychainHelper.load(key: apiKeyKeychainKey),
              !stored.isEmpty else { return }
        // Suppress the `apiKey.didSet` write-through for this one assignment
        // so adopting the stored value doesn't re-save it (a redundant Keychain
        // write that could itself prompt).
        isAdoptingStoredAPIKey = true
        openAIAPIKey = stored
        isAdoptingStoredAPIKey = false
    }

    /// Default name prompt is deliberately *tool-free*. The previous default
    /// asked claude to read the Mac calendar, which made the CLI hang trying
    /// to use an MCP it didn't have — the symptom users hit was "Suggest
    /// never returns". Plain summarisation is the safe baseline; calendar
    /// lookup is offered as an example for users whose claude/cursor setup
    /// genuinely has that integration wired up.
    static let defaultNamePrompt =
        "Read the transcript below and reply with a 3–6 word title for it. Respond with just the title — no quotes, no punctuation, no preamble."
    static let defaultActionPrompt =
        "Summarize the transcript below as bullet points."

    /// Example pairs surfaced in the Settings UI as a "you could try…" hint.
    static let nameExamples: [String] = [
        "Read the transcript below and reply with a 3–6 word title — no quotes, no punctuation.",
        "If you have my Mac calendar configured, use the title of the current event; otherwise summarise the transcript in 3–6 words.",
        "Extract the most-mentioned topic from the transcript and use it as the title (3–6 words)."
    ]
    static let actionExamples: [String] = [
        "Summarize this and email the summary to the meeting attendees.",
        "Extract action items as a Markdown checklist and append to my daily note.",
        "Translate this transcript to English and copy to my clipboard."
    ]

    private enum Keys {
        static let tool = "llm.tool"
        static let executablePath = "llm.executablePath"
        static let nameEnabled = "llm.name.enabled"
        static let namePrompt = "llm.name.prompt"
        static let actionEnabled = "llm.action.enabled"
        static let actionPrompt = "llm.action.prompt"
        static let actionTranscriptByPath = "llm.action.transcriptByPath"
        static let summaryEnabled = "llm.summary.enabled"
        static let cliTimeout = "llm.cli.timeout"
        static let extraArgs = "llm.extraArgs"
        static let openAIProvider = "llm.openai.provider"
        static let openAIBaseURL = "llm.openai.baseURL"
        static let openAIModelName = "llm.openai.modelName"
        static let openAIAPIKey = "llm.openai.apiKey"   // Keychain item, not UserDefaults
    }
}
