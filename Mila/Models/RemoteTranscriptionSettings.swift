import Foundation
import Combine
import TranscriptionCore

/// Which engine Mila uses to turn audio into text. A single app-wide choice,
/// mirroring the privacy-first default: on-device whisper.cpp unless the user
/// deliberately opts into a remote endpoint.
enum TranscriptionBackend: String, CaseIterable, Identifiable, Codable {
    /// In-process whisper.cpp (the default). Audio never leaves the device.
    case local
    /// An OpenAI-compatible `/v1/audio/transcriptions` endpoint — OpenAI's own
    /// API or any self-hosted server that speaks the same protocol (e.g.
    /// `speaches` serving an ivrit.ai model). Audio is uploaded off-device.
    case remote

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local:  return "On-device"
        case .remote: return "Remote API"
        }
    }
}

/// Immutable snapshot handed to `RemoteWhisperEngine` for one transcription.
/// `Sendable` so it can cross from the `@MainActor` settings object to the
/// engine actor without a data race.
struct RemoteTranscriptionConfig: Sendable, Equatable {
    /// Base URL, e.g. `https://api.openai.com/v1`. The engine appends
    /// `audio/transcriptions`.
    var endpoint: URL
    /// Bearer token. Empty for self-hosted servers that don't authenticate.
    var apiKey: String
    /// Model identifier the server expects, e.g. `whisper-1` (OpenAI) or
    /// `ivrit-ai/whisper-large-v3-turbo-ct2` (a self-hosted faster-whisper).
    var model: String
}

/// User-configurable remote transcription backend. Opt-in, off by default.
///
/// Follows the app's settings conventions: namespaced `UserDefaults` keys for
/// non-secret values, and the **Keychain** for the API token so it's encrypted
/// at rest rather than sitting in the plist. Constructed once in
/// `MilaApp.init()` and injected via `.environmentObject` on both scenes.
@MainActor
final class RemoteTranscriptionSettings: ObservableObject {
    /// Result of the last "Test connection" attempt. Advisory only — it never
    /// gates transcription. On success it carries the text the server
    /// transcribed from the bundled sample clip, so the user can confirm the
    /// endpoint, token, and model actually produce a correct result.
    enum TestStatus: Equatable {
        case idle
        case testing
        case ok(String)
        case failed(String)
    }

    @Published var backend: TranscriptionBackend {
        didSet {
            guard backend != oldValue else { return }
            defaults.set(backend.rawValue, forKey: Keys.backend)
            // Defer the Keychain read until the user actually switches to the
            // remote backend (see `loadAPIKeyIfNeeded`). Local-only users never
            // trigger the macOS "Mila wants to use confidential information"
            // prompt because we never touch the Keychain for them.
            if backend == .remote { loadAPIKeyIfNeeded() }
        }
    }

    @Published var endpoint: String {
        didSet {
            guard endpoint != oldValue else { return }
            defaults.set(endpoint, forKey: Keys.endpoint)
            testStatus = .idle
        }
    }

    @Published var model: String {
        didSet {
            guard model != oldValue else { return }
            defaults.set(model, forKey: Keys.model)
            // Reconcile in BOTH directions. Pointing at a Hebrew-only model is
            // exactly when an English model is needed, so fill it in at that
            // moment rather than waiting for the user to notice English
            // transcripts coming back in Hebrew — and drop the pre-filled id
            // again when the primary stops being Hebrew-only, because it
            // belongs to that primary and breaks the next one.
            reconcileEnglishModelForCurrentPrimary()
            // The probe is model-specific -- it uploads a clip and asks this
            // model to transcribe it -- so a green tick earned by the previous
            // model says nothing about the new one. Same reset that `endpoint`
            // and `apiKey` already do.
            testStatus = .idle
        }
    }

    /// Optional second model id, used for English and auto-detect recordings.
    ///
    /// Exists because a server's main model may be *language-specific*: the
    /// ivrit.ai finetune Mila's own server runs is Hebrew-only, and sending it
    /// English audio yields English speech rendered with Hebrew words spliced
    /// in — `language=en` is honoured by the decoder but can't fix weights that
    /// were never trained multilingual. A single model id had no way to express
    /// "Hebrew here, English there".
    ///
    /// Empty means "use `model` for every language", which is correct for
    /// genuinely multilingual endpoints like OpenAI's `whisper-1`.
    ///
    /// **Pre-filled for Hebrew-only endpoints.** When `model` is an ivrit.ai id
    /// this is populated with `defaultEnglishModel` (see `prefillEnglishModelIfNeeded`)
    /// rather than left blank. Shipping it blank meant upgrading changed nothing
    /// until the user found the field — the bug was "fixed" in the binary and
    /// still happening on screen. Clearing it by hand is respected and never
    /// re-filled, and a pre-filled value is withdrawn again if the primary
    /// stops being Hebrew-only.
    @Published var englishModel: String {
        didSet {
            guard englishModel != oldValue else { return }
            defaults.set(englishModel, forKey: Keys.englishModel)
            guard !isProgrammaticWrite else { return }
            // Past here the edit is the user's, so the value is theirs: Mila no
            // longer owns it and must not withdraw it on a later model change.
            defaults.set(false, forKey: Keys.englishModelAutoFilled)
            // An explicit clear is a decision, not an absence. Record it so no
            // later prefill (a fresh launch, or editing `model`) overrides it.
            if englishModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !oldValue.isEmpty {
                defaults.set(true, forKey: Keys.englishModelCleared)
            }
        }
    }

    /// The bearer token. Stored in the Keychain, never in `UserDefaults`. The
    /// `@Published` mirror lets SwiftUI bind a `SecureField` directly; every
    /// edit writes through to the Keychain.
    @Published var apiKey: String {
        didSet {
            guard apiKey != oldValue else { return }
            // Skip the write-back when we're just adopting the value we read
            // from the Keychain — re-saving it would be a redundant write that
            // could itself trigger a Keychain prompt.
            guard !isAdoptingStoredAPIKey else { return }
            KeychainHelper.save(key: apiKeyKeychainKey, value: apiKey)
            testStatus = .idle
        }
    }

    @Published private(set) var testStatus: TestStatus = .idle

    static let defaultEndpoint = "https://api.openai.com/v1"
    static let defaultModel = "whisper-1"

    /// The English/multilingual model pre-filled for Hebrew-only endpoints: a
    /// CTranslate2 build of Whisper large-v3-turbo, which is what Mila's own
    /// `mila-asr` server warms alongside the ivrit finetune. Turbo rather than
    /// full large-v3 because the live path sends one utterance at a time and
    /// latency shows.
    static let defaultEnglishModel = "deepdml/faster-whisper-large-v3-turbo-ct2"

    /// Whether `modelID` names a Hebrew-only ivrit.ai finetune — the case that
    /// needs a separate English model. Substring match on `ivrit`, which covers
    /// every published variant (`ivrit-ai/whisper-large-v3-turbo-ct2`,
    /// `ivrit-ai/whisper-large-v3-ggml`, …) and any local rehost that keeps the
    /// name. Pure + `static` so the prefill rule is testable on its own.
    static func isHebrewOnlyModel(_ modelID: String) -> Bool {
        modelID.lowercased().contains("ivrit")
    }

    // MARK: - Known-good presets

    /// The catalogue entry the current `model` names, or `nil` for a model id
    /// Mila has no entry for (the picker's *Custom…*).
    ///
    /// **Derived, not stored.** A persisted "selected preset" would be a second
    /// copy of a fact `model` already carries, and the two have several ways to
    /// disagree — a `.milaconfig` import writes `model` directly
    /// (`MilaConfigImporter`), as does anything editing the raw field. Deriving
    /// it means an imported configuration shows up correctly identified in the
    /// picker with no import-side change at all.
    /// Matched against the **effective** model, not the raw field. `resolve`
    /// turns a blank or whitespace-only value into `defaultModel`, so an empty
    /// field transcribes as `whisper-1` — matching the raw text would show
    /// "Custom..." for a configuration that is in fact the default preset.
    var selectedPreset: RemoteModelPreset? { RemoteModelPreset.matching(Self.resolve(model)) }

    /// Adopt a preset: its model id, and its endpoint when the one configured
    /// isn't the user's own.
    ///
    /// The endpoint rule is deliberately conservative. Switching from the
    /// OpenAI group to a self-hosted model has to move the endpoint or the
    /// choice is incoherent, but a URL the user typed — a private gateway, a
    /// reverse proxy — can serve any of these ids, so overwriting it would
    /// break a working setup on an unrelated edit. Preset endpoints are
    /// therefore only ever replaced by other preset endpoints (or filled in
    /// when the current value can't be parsed at all).
    ///
    /// `englishModel` is *not* touched here: `model`'s own `didSet` already
    /// reconciles it for a Hebrew-only primary, so picking the ivrit preset
    /// gets the English prefill — and picking anything else gets the matching
    /// withdrawal — through the one code path that owns that rule.
    func apply(_ preset: RemoteModelPreset) {
        if shouldAdoptEndpoint(of: preset) {
            endpoint = preset.endpoint
        }
        model = preset.id
    }

    /// Whether `apply(_:)` may replace the configured endpoint. True when the
    /// current value is one the presets own, or isn't a usable URL.
    private func shouldAdoptEndpoint(of preset: RemoteModelPreset) -> Bool {
        guard endpointURL != nil else { return true }
        let current = RemoteModelPreset.normalizeEndpoint(endpoint)
        guard RemoteModelPreset.canonicalEndpoints.contains(current) else { return false }
        return current != RemoteModelPreset.normalizeEndpoint(preset.endpoint)
    }

    private let defaults: UserDefaults
    private let urlSession: URLSession
    /// Keychain item the API token is stored under. Injectable so tests /
    /// previews / alternate instances don't read or clobber the real app's
    /// `remote.apiKey` item (mirrors how `defaults` is injected).
    private let apiKeyKeychainKey: String
    /// Whether the stored token has been read from the Keychain yet. Guards the
    /// lazy load so it happens at most once, and so an explicit user edit before
    /// the first switch to remote isn't clobbered by a later load.
    private var hasLoadedAPIKey = false

    init(defaults: UserDefaults = .standard,
         urlSession: URLSession = .shared,
         apiKeyKeychainKey: String = Keys.apiKey) {
        self.defaults = defaults
        self.urlSession = urlSession
        self.apiKeyKeychainKey = apiKeyKeychainKey
        self.backend = TranscriptionBackend(rawValue: defaults.string(forKey: Keys.backend) ?? "")
            ?? .local
        self.endpoint = defaults.string(forKey: Keys.endpoint) ?? Self.defaultEndpoint
        self.model = defaults.string(forKey: Keys.model) ?? Self.defaultModel
        self.englishModel = defaults.string(forKey: Keys.englishModel) ?? ""
        // Start empty and defer the Keychain read. Reading the token at launch
        // unconditionally pops the macOS "Mila wants to use confidential
        // information stored in your keychain" prompt for *every* user — even
        // the local-only majority who never configure a remote endpoint. We
        // only read once the user actually selects the remote backend (here if
        // it's the restored choice, otherwise lazily in `backend.didSet`).
        self.apiKey = ""
        if backend == .remote { loadAPIKeyIfNeeded() }
        // Upgrade path: everyone already pointed at an ivrit.ai endpoint before
        // per-language routing existed has a blank English model, and a blank
        // one means "use the Hebrew model for English too" — i.e. the bug this
        // shipped to fix, still happening. Fill it in on first launch.
        //
        // The withdraw side runs here too, so "an auto-filled English model
        // implies a Hebrew-only primary" holds at every point, not just across
        // an in-session model edit. A no-op for anyone upgrading: the
        // auto-filled flag is only ever set by Mila's own prefill, so a value
        // that predates this code is treated as the user's and left alone.
        reconcileEnglishModelForCurrentPrimary()
    }

    /// Bring `englishModel` into line with the current primary, by running both
    /// halves of the rule. Exactly one of them can act on any given primary —
    /// the withdrawal only for a non-ivrit `model`, the prefill only for an
    /// ivrit one — so this is about never running one without the other, not
    /// about sequencing them. Every entry point (`init`, `model.didSet`) goes
    /// through here so a third one can't arrive with only half the rule.
    private func reconcileEnglishModelForCurrentPrimary() {
        clearAutoFilledEnglishModelIfNeeded()
        prefillEnglishModelIfNeeded()
    }

    /// Assign `englishModel` on Mila's own behalf and record whether the value
    /// is one Mila owns, without `englishModel.didSet` mistaking the write for
    /// a user edit. `defer` rather than a trailing assignment so an early
    /// return added later can't leave the flag stuck `true` — which would
    /// silently stop the next real user edit from claiming ownership.
    private func setEnglishModelProgrammatically(_ value: String, autoFilled: Bool) {
        isProgrammaticWrite = true
        defer { isProgrammaticWrite = false }
        englishModel = value
        defaults.set(autoFilled, forKey: Keys.englishModelAutoFilled)
    }

    /// Set `englishModel` to `defaultEnglishModel` when the primary model is
    /// Hebrew-only and the user hasn't chosen otherwise.
    ///
    /// Deliberately narrow — it fires only for ivrit.ai primaries. A blank
    /// English model is *correct* for a multilingual endpoint (OpenAI's
    /// `whisper-1`, a plain `Systran/faster-whisper-large-v3` deployment), and
    /// filling one in there would send a model id the server doesn't have and
    /// break English outright. Wrong-language text is bad; a hard failure is
    /// worse.
    ///
    /// No-ops when: the field already has a value, the user explicitly cleared
    /// it (`Keys.englishModelCleared`), or the primary isn't ivrit.
    private func prefillEnglishModelIfNeeded() {
        guard englishModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !defaults.bool(forKey: Keys.englishModelCleared) else { return }
        guard Self.isHebrewOnlyModel(model) else { return }
        setEnglishModelProgrammatically(Self.defaultEnglishModel, autoFilled: true)
    }

    /// Withdraw an auto-filled `englishModel` once the primary is no longer
    /// Hebrew-only — the other half of the prefill, and the same reasoning.
    ///
    /// The pre-filled id exists only to serve an ivrit primary. Leaving it
    /// behind when the user switches to a multilingual endpoint would send that
    /// endpoint a model id it doesn't have and break English outright, which is
    /// precisely the failure `prefillEnglishModelIfNeeded` refuses to cause in
    /// the first place. Withdrawing it restores "English uses the primary".
    ///
    /// Only touches values Mila wrote itself (`Keys.englishModelAutoFilled`). A
    /// model id the user typed is theirs and survives any primary change; so
    /// does an explicit clear, which leaves nothing to withdraw.
    private func clearAutoFilledEnglishModelIfNeeded() {
        guard !Self.isHebrewOnlyModel(model) else { return }
        guard defaults.bool(forKey: Keys.englishModelAutoFilled) else { return }
        // Not a user clear, so this must not set `Keys.englishModelCleared` —
        // switching back to an ivrit primary should pre-fill again.
        setEnglishModelProgrammatically("", autoFilled: false)
    }

    /// True only while this class is assigning `englishModel` itself, so the
    /// write-back can tell its own fill/withdraw from a user edit.
    private var isProgrammaticWrite = false

    /// Lazily read the bearer token from the Keychain the first time the remote
    /// backend is selected. Idempotent (guarded by `hasLoadedAPIKey`) and
    /// non-destructive: if the user has already typed a key we keep theirs
    /// rather than overwrite it with the stored value.
    private func loadAPIKeyIfNeeded() {
        guard !hasLoadedAPIKey else { return }
        hasLoadedAPIKey = true
        // Don't clobber an in-progress edit. Only adopt the stored token when
        // the in-memory field is still empty.
        guard apiKey.isEmpty else { return }
        guard let stored = KeychainHelper.load(key: apiKeyKeychainKey), !stored.isEmpty else { return }
        // Assigning here triggers `apiKey.didSet`, but since `stored != ""` only
        // when it differs from the current empty value, the write-through guard
        // (`guard apiKey != oldValue`) lets it pass and re-saves the identical
        // value. KeychainHelper.save is delete-then-add, so writing the same
        // value back is harmless — but to avoid even that redundant Keychain
        // write (which could itself prompt), suppress the write-through for this
        // one assignment.
        isAdoptingStoredAPIKey = true
        apiKey = stored
        isAdoptingStoredAPIKey = false
    }

    /// Set only while `loadAPIKeyIfNeeded` adopts the stored token, so the
    /// `apiKey.didSet` write-through skips re-saving a value we just read.
    private var isAdoptingStoredAPIKey = false

    /// True when the user has chosen the remote backend (regardless of whether
    /// it's fully configured). Drives routing in `TranscriptionService`.
    var isActive: Bool { backend == .remote }

    /// Parsed, validated base URL — `nil` if the string isn't a usable
    /// absolute http(s) URL.
    var endpointURL: URL? {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    /// "Enabled AND ready to use" — the invariant the routing layer relies on
    /// before it skips the local-model gate. The endpoint must parse, and
    /// OpenAI's own endpoint additionally needs an API key (self-hosted servers
    /// usually accept anonymous requests, so we don't force a token there).
    var isConfigured: Bool {
        guard isActive, let url = endpointURL else { return false }
        if Self.requiresAPIKey(url) {
            return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    /// The model id to send for a recording in `languageCode` — the remote
    /// mirror of `ModelManager.model(for:)`, which does the same routing for the
    /// on-device backend.
    ///
    /// * `he` (and legacy `iw`/unrecognised codes) → `model`, the primary.
    /// * `en` → `englishModel`.
    /// * legacy `auto` → `englishModel`, the only one that can serve a
    ///   detect-the-language request. Auto-detect was retired as a user
    ///   choice (see `RecordingLanguage`), but recordings made under it keep
    ///   the string on disk and can still be re-transcribed.
    ///
    /// With `englishModel` empty every language resolves to the primary, so a
    /// single-model endpoint behaves exactly as it did before this existed.
    func model(for languageCode: String) -> String {
        let primary = Self.resolve(model)
        let english = englishModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !english.isEmpty else { return primary }
        if languageCode.lowercased() == "auto" { return english }
        switch RecordingLanguage.fromCode(languageCode) {
        case .hebrew:   return primary
        case .english:  return english
        }
    }

    /// Trim a user-entered model id, falling back to the default when blank.
    private static func resolve(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    /// Snapshot for the engine, or `nil` if the endpoint can't be parsed.
    ///
    /// Pass the recording's language so the right model id is baked into the
    /// snapshot; omit it (the connection probe does) to get the primary model.
    func currentConfig(for languageCode: String? = nil) -> RemoteTranscriptionConfig? {
        guard let url = endpointURL else { return nil }
        return RemoteTranscriptionConfig(
            endpoint: url,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: languageCode.map(model(for:)) ?? Self.resolve(model)
        )
    }

    /// Human-readable label written to `Recording.modelName` when a remote
    /// transcription completes (so the detail view shows where the text came
    /// from).
    var modelLabel: String {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Remote · \(trimmedModel.isEmpty ? Self.defaultModel : trimmedModel)"
    }

    /// OpenAI's hosted API rejects unauthenticated requests, so we treat a key
    /// as mandatory there. Self-hosted endpoints are assumed open unless the
    /// user supplies one.
    static func requiresAPIKey(_ url: URL) -> Bool {
        (url.host ?? "").lowercased().hasSuffix("openai.com")
    }

    /// A short Hebrew clip ("שלום עולם") bundled in the app. `testConnection`
    /// uploads it and checks a transcription comes back — a genuine end-to-end
    /// check (auth accepted, model loaded, transcription works) rather than a
    /// bare `GET /models` that only proves the server answers HTTP.
    private static let testSampleResource = "ConnectionTestSample"
    /// The bundled clip is Hebrew; force `he` so the ivrit model (Hebrew-only)
    /// and multilingual models alike transcribe it accurately, independent of
    /// the user's recording-language setting.
    private static let testSampleLanguage = "he"

    /// Send the bundled sample clip to `/audio/transcriptions` and verify the
    /// server returns a real transcription. Purely advisory — surfaced as a
    /// status pill in Settings; it never gates transcription. The user sees the
    /// transcribed text on success, so they can eyeball that it's correct.
    func testConnection() async {
        guard let url = endpointURL else {
            testStatus = .failed("Enter a valid http(s) URL.")
            return
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = currentConfig()?.model ?? Self.defaultModel
        testStatus = .testing

        guard let sampleURL = Bundle.main.url(forResource: Self.testSampleResource,
                                              withExtension: "wav") else {
            testStatus = .failed("Missing bundled test clip.")
            return
        }

        // Build the request through the exact same path a real recording takes
        // (WAV → 16 kHz mono → m4a → multipart), so a success genuinely proves
        // the upload+transcribe pipeline works.
        let boundary = "MilaBoundary-\(UUID().uuidString)"
        let body: Data
        do {
            let samples = try WAVReader.loadSamples(url: sampleURL)
            let audio = try await RemoteWhisperEngine.encodeM4A(samples: samples)
            body = RemoteWhisperEngine.multipartBody(boundary: boundary,
                                                     audio: audio,
                                                     model: model,
                                                     language: Self.testSampleLanguage)
        } catch {
            testStatus = .failed("Couldn't prepare the test clip: \(error.localizedDescription)")
            return
        }

        var request = URLRequest(url: url.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, response) = try await urlSession.upload(for: request, from: body)
            // Drop the result if the user changed the endpoint, key or model
            // while the request was in flight — `didSet` already reset status
            // to .idle, and a stale result for the previous values would be
            // misleading. The model matters as much as the other two: the probe
            // asks one specific model to transcribe, so applying its verdict
            // after a switch would show a pass earned by a different model.
            guard endpointURL == url,
                  apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == key,
                  (currentConfig()?.model ?? Self.defaultModel) == model else { return }
            guard let http = response as? HTTPURLResponse else {
                testStatus = .failed("No HTTP response.")
                return
            }
            testStatus = Self.evaluateProbe(statusCode: http.statusCode, data: data)
        } catch {
            guard endpointURL == url,
                  apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == key,
                  (currentConfig()?.model ?? Self.defaultModel) == model else { return }
            testStatus = .failed(error.localizedDescription)
        }
    }

    /// Map a transcription-probe HTTP response to a user-facing status. Pure so
    /// it's unit-testable without a network or the bundled clip.
    static func evaluateProbe(statusCode: Int, data: Data) -> TestStatus {
        switch statusCode {
        case 401, 403:
            return .failed("Authentication failed (HTTP \(statusCode)). Check the API key.")
        case 200..<300:
            let text = ((try? RemoteWhisperEngine.parseSegments(data: data)) ?? [])
                .map(\.text).joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return .failed("Server accepted the request but returned no transcription — check the model id.")
            }
            return .ok("Transcribed the test clip: “\(text)”")
        default:
            return .failed("Server returned HTTP \(statusCode).")
        }
    }

    private enum Keys {
        static let backend = "transcription.backend"
        static let endpoint = "remote.endpoint"
        static let model = "remote.model"
        static let englishModel = "remote.model.en"
        /// Set once the user empties `englishModel` by hand, so the prefill
        /// never overrides that choice on a later launch or model edit.
        static let englishModelCleared = "remote.model.en.cleared"
        /// True while the current `englishModel` is one Mila pre-filled rather
        /// than one the user typed — so it can be withdrawn again if the primary
        /// stops being Hebrew-only, without ever discarding the user's own value.
        static let englishModelAutoFilled = "remote.model.en.autofilled"
        static let apiKey = "remote.apiKey"
    }
}
