import Foundation
import Combine
import OSLog

private let summarizerLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                   category: "RecordingSummarizer")

/// Fires a one-shot LLM call against a finished recording's transcript and
/// stores the result on the `Recording.summary` field.
///
/// Three entry points:
///   * `summarizeIfNeeded(_:)` — fired by the post-transcription hook for
///     every freshly-transcribed recording. Skips work when a live summary
///     is already there.
///   * `regenerate(_:)` — explicit user action (Re-transcribe completion +
///     "Regenerate summary" context menu). Bypasses the
///     "already has summary" gate so the old summary is replaced.
///   * `backfillIfNeeded()` — called on launch and on LLM-config flip
///     (off→on). Scans the store for completed recordings missing a
///     summary and queues them through `summarizeIfNeeded` with a
///     concurrency cap so we don't melt the user's API quota.
///
/// Uses the same `LLMRunner` + sandboxing the rename sheet's "Send to
/// Claude" path uses, so any `$PATH` / TCC-popup mitigations carry over
/// for free.
@MainActor
final class RecordingSummarizer: ObservableObject {
    private let store: RecordingStore
    private let llmSettings: LLMSettings
    private let liveAISettings: LiveAISettings

    /// The LLM invocation, behind a seam so tests don't have to spawn a
    /// real subprocess. Production wires this to `LLMRunner.run`, which
    /// shells out to the configured `claude` / `cursor-agent` CLI. Tests
    /// inject a closure that returns canned output synchronously, so the
    /// summarizer's store-write logic is exercised without depending on
    /// process spawn / exec / pipe-drain timing — the source of the
    /// residual CI flake (the assertion lands deterministically because no
    /// child process is involved). The closure receives the same arguments
    /// the summarizer would have forwarded to the CLI, so a test can still
    /// assert on the wire shape (e.g. the one-shot `-p` prompt built by
    /// `LLMTool.arguments`) by inspecting them directly instead of
    /// capturing a shell script's argv.
    ///
    /// `@MainActor` so a test stub can read/write main-actor-isolated test
    /// fixtures (e.g. capture the argv it was handed) without Sendable
    /// gymnastics — the whole summarizer already runs on the main actor.
    typealias RunLLM = @MainActor (
        _ tool: LLMTool,
        _ prompt: String,
        _ transcript: String,
        _ executablePathOverride: String?,
        _ model: String?,
        _ extraArgs: [String],
        _ timeout: TimeInterval,
        _ openAIBaseURL: String?,
        _ openAIAPIKey: String?,
        _ jsonMode: Bool,
        _ transport: OpenAITransport?
    ) async throws -> String

    private let runLLM: RunLLM

    /// Background work tracked per-recording so a second `summarizeIfNeeded`
    /// call for the same id (e.g. a re-transcribe trigger) doesn't spawn
    /// two overlapping CLI invocations.
    ///
    /// Published as a set so detail views can show a "Summarizing…"
    /// spinner on the summary section while a call is in flight (used by
    /// the "Regenerate summary" affordance + backfill).
    @Published private(set) var inFlightIDs: Set<UUID> = []
    private var inFlight: [UUID: Task<Void, Never>] = [:]

    /// Fired once per summarize attempt, after the recording's summary state
    /// is final — i.e. after a summary was generated, or synchronously when
    /// generation was skipped (disabled / not configured / already summarized
    /// / empty transcript), or when it failed. Passes the latest recording.
    ///
    /// The Obsidian exporter uses this to write a note only once the summary +
    /// action items are ready, falling back to the transcript when no summary
    /// was produced. It is NOT fired for the dedup early-return (a duplicate
    /// call while one is already in flight — the in-flight task fires instead)
    /// or when the recording has been deleted mid-flight (nothing to export;
    /// this covers the failure and empty-output paths too, not just success —
    /// `cancel(recordingID:)` is what a permanent delete calls, and that
    /// surfaces here as a thrown `CancellationError`).
    ///
    /// Exactly one of the branches below fires it per attempt, and each one
    /// returns immediately afterwards, so a single `runSummary` can never fire
    /// twice. Anything the observer does is its own problem: this is a plain
    /// synchronous call on the main actor, so an observer that throws is a
    /// programmer error, but an observer that *fails internally* (e.g. a file
    /// write that can't complete) cannot stall or corrupt summarisation —
    /// nothing downstream of the call site depends on it.
    var onSummaryFinished: ((Recording) -> Void)?

    /// Recordings the backfill scan has identified as needing a summary
    /// but hasn't started yet — held here so `maxConcurrent` is enforced
    /// across the whole batch instead of letting all candidates spawn at
    /// once.
    private var backfillQueue: [UUID] = []

    /// Max concurrent in-flight CLI invocations the summarizer will
    /// schedule from backfill / regeneration. Starts at 2 — high enough
    /// that two recordings get summarized at app launch in parallel but
    /// low enough that a 20-recording catch-up sweep doesn't fork 20
    /// `claude -p` subprocesses on the user's machine.
    var maxConcurrent: Int = 2

    /// Subscribers held for the lifetime of the summarizer. We watch
    /// `LLMSettings.$tool` so a user who configures their CLI mid-session
    /// gets an automatic backfill sweep the moment the toggle flips.
    private var cancellables: Set<AnyCancellable> = []

    /// Timeout for the one-shot summary call. Reads from `LLMSettings.cliTimeout`
    /// so it follows the user's preference set in Settings → AI Provider.
    var timeoutSeconds: TimeInterval { llmSettings.cliTimeout }

    /// `runLLM` defaults to the real CLI invocation (`LLMRunner.run`).
    /// Tests pass a deterministic stub to remove the subprocess-timing
    /// dependency. The default forwards exactly the arguments
    /// `runSummary` collects so production behaviour is unchanged.
    init(store: RecordingStore,
         llmSettings: LLMSettings,
         liveAISettings: LiveAISettings,
         runLLM: @escaping RunLLM = { tool, prompt, transcript, executableOverride, model, extraArgs, timeout, openAIBaseURL, openAIAPIKey, jsonMode, transport in
             try await LLMRunner.run(
                 tool: tool,
                 prompt: prompt,
                 transcript: transcript,
                 executablePathOverride: executableOverride,
                 model: model,
                 extraArgs: extraArgs,
                 timeout: timeout,
                 openAIBaseURL: openAIBaseURL,
                 openAIAPIKey: openAIAPIKey,
                 jsonMode: jsonMode,
                 transport: transport,
                 // The summarizer has exactly one purpose, so the label is
                 // fixed here rather than threaded through the `RunLLM` seam.
                 feature: .summary
             )
         }) {
        self.store = store
        self.llmSettings = llmSettings
        self.liveAISettings = liveAISettings
        self.runLLM = runLLM

        // Backfill on off→on transitions of LLM configured-ness. The
        // `tool` property is the only one that affects `isConfigured`
        // today; observing it directly (rather than the computed
        // `isConfigured`) means we don't need to expose a publisher on
        // the computed property.
        //
        // `@Published` emits from `willSet` — i.e. the sink fires
        // BEFORE the property has been updated, so `llmSettings.tool`
        // and `llmSettings.isConfigured` still report the OLD value at
        // sink time. `Task { @MainActor }` from a main-actor caller
        // can resume on the same actor tick (Swift's scheduler does not
        // guarantee a real runloop hop), so reading `isConfigured`
        // inside the Task body still saw the old value in CI.
        //
        // `.receive(on: DispatchQueue.main)` shifts delivery onto the
        // next main-queue tick via `dispatch_async`, which is a hard
        // boundary: by the time the sink runs, the @Published setter
        // has fully completed (storage written, didSet invoked) so
        // `isConfigured` reflects the new value.
        llmSettings.$tool
            .map { $0 != .none }
            .removeDuplicates()
            .dropFirst()  // ignore the initial value emitted by @Published
            .receive(on: DispatchQueue.main)
            .sink { [weak self] nowConfigured in
                guard let self, nowConfigured else { return }
                summarizerLog.log("llm configured flipped on — scheduling backfill")
                self.backfillIfNeeded()
            }
            .store(in: &cancellables)
    }

    // MARK: - Predicates

    /// Returns true iff `recording` needs (and can get) a one-shot summary
    /// under the normal (non-force) gate.
    /// Public so callers + tests can ask the same question we ask
    /// internally without re-deriving the predicate.
    func shouldSummarize(_ recording: Recording) -> Bool {
        guard llmSettings.summaryEnabled else { return false }
        guard llmSettings.isConfigured else { return false }
        let transcript = recording.fullText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty { return false }
        let existing = (recording.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !existing.isEmpty { return false }
        return true
    }

    /// True while a summary CLI call is in flight for `recordingID`.
    /// Used by the detail view to show a "Summarizing…" spinner on the
    /// summary section.
    func isSummarizing(_ recordingID: UUID) -> Bool {
        inFlightIDs.contains(recordingID)
    }

    /// Await the in-flight summary task for `recordingID`, if one is running.
    /// Returns immediately when nothing is in flight (already finished, or
    /// never started). Test seam: lets tests wait on the REAL completion
    /// signal — the underlying `Task` finishing — instead of polling the
    /// store on a timer. Polling is inherently racy under CI contention (the
    /// subprocess spawn + pipe drain can slip past a fixed window); awaiting
    /// the task itself is deterministic. The task clears its own `inFlight`
    /// entry in a `defer`, so by the time this returns the store write (if any)
    /// has already happened.
    func awaitInFlight(_ recordingID: UUID) async {
        guard let task = inFlight[recordingID] else { return }
        await task.value
    }

    // MARK: - Public API

    /// Kick off a background summary for `recording` if the gate above
    /// allows. Returns immediately — the caller doesn't await the LLM.
    /// Idempotent: a second call while one is in flight is a no-op so a
    /// re-enqueue from the transcription path can't double-bill.
    func summarizeIfNeeded(_ recording: Recording) {
        guard shouldSummarize(recording) else {
            logSkip(recording, force: false)
            // No summary will be generated — signal completion now so a
            // pending Obsidian export falls back to the transcript.
            onSummaryFinished?(latestRecording(recording.id, fallback: recording))
            return
        }
        runSummary(for: recording, force: false)
    }

    /// Force-regenerate a summary for `recording`, bypassing the
    /// "already has a summary" gate. Used by:
    ///   * `TranscriptionService`'s onTranscriptionCompleted callback
    ///     when the completed recording was a re-transcription (the old
    ///     summary refers to the now-replaced transcript).
    ///   * The "Regenerate summary" context-menu action.
    ///
    /// Still respects the two hard requirements: LLM must be configured,
    /// transcript must be non-empty. Returns immediately.
    func regenerate(_ recording: Recording) {
        guard llmSettings.isConfigured else {
            summarizerLog.log("regenerate \(self.shortID(recording.id), privacy: .public): skipped — LLM not configured")
            onSummaryFinished?(latestRecording(recording.id, fallback: recording))
            return
        }
        let transcript = recording.fullText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            summarizerLog.log("regenerate \(self.shortID(recording.id), privacy: .public): skipped — transcript empty")
            onSummaryFinished?(latestRecording(recording.id, fallback: recording))
            return
        }
        runSummary(for: recording, force: true)
    }

    /// Scan the store for completed recordings missing a summary, then
    /// process them newest-first with at most `maxConcurrent` in-flight
    /// CLI invocations. No-op when the LLM CLI isn't configured (the
    /// constructor's `$tool` subscriber re-runs the scan once that
    /// changes).
    ///
    /// Idempotent: re-runs are safe — recordings already in flight are
    /// skipped by `runSummary`'s own dedup check.
    func backfillIfNeeded() {
        guard llmSettings.summaryEnabled else {
            summarizerLog.log("backfill: skipped — auto-summary disabled")
            return
        }
        guard llmSettings.isConfigured else {
            summarizerLog.log("backfill: skipped — LLM not configured")
            return
        }
        // Newest-first: scan in the same order RecordingStore keeps its
        // array (createdAt descending) so the recording the user just
        // made gets attention before the months-old archive.
        let candidates: [Recording] = store.recordings.filter { rec in
            guard rec.status == .completed else { return false }
            guard !rec.isTrashed else { return false }
            let transcript = rec.fullText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { return false }
            let existing = (rec.summary ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return existing.isEmpty
        }
        guard !candidates.isEmpty else {
            summarizerLog.log("backfill: nothing to do")
            return
        }
        summarizerLog.log("backfill: \(candidates.count, privacy: .public) candidate(s) queued (concurrency=\(self.maxConcurrent, privacy: .public))")
        // Append rather than replace so a config-flip-triggered re-scan
        // that runs while a previous backfill is still draining doesn't
        // drop in-progress IDs. The dedup guard inside `runSummary`
        // covers duplicate enqueues.
        for rec in candidates {
            if !backfillQueue.contains(rec.id),
               !inFlight.keys.contains(rec.id) {
                backfillQueue.append(rec.id)
            }
        }
        pumpBackfill()
    }

    /// Cancel any in-flight summary work for `recordingID`. Used when a
    /// recording is being permanently deleted so we don't spend a CLI
    /// call on output that has nowhere to land.
    func cancel(recordingID: UUID) {
        backfillQueue.removeAll { $0 == recordingID }
        if let task = inFlight.removeValue(forKey: recordingID) {
            task.cancel()
            inFlightIDs.remove(recordingID)
        }
    }

    // MARK: - Internals

    /// Drain `backfillQueue` up to the concurrency cap. Re-invoked from
    /// each task's `defer` so as soon as one finishes the next one can
    /// start.
    private func pumpBackfill() {
        while inFlight.count < maxConcurrent, !backfillQueue.isEmpty {
            let id = backfillQueue.removeFirst()
            guard let rec = store.recordings.first(where: { $0.id == id }) else {
                continue
            }
            // Re-check the gate — the recording may have been trashed,
            // re-transcribed, or summarized via another code path
            // between scan time and now.
            guard shouldSummarize(rec) else { continue }
            runSummary(for: rec, force: false)
        }
    }

    /// Common path used by `summarizeIfNeeded` and `regenerate`.
    /// `force` controls whether an already-present summary is overwritten
    /// when the CLI returns.
    private func runSummary(for recording: Recording, force: Bool) {
        let id = recording.id
        // Dedup: a re-enqueue from the transcription path or a second
        // "Regenerate" tap while the first is in flight is a no-op so a
        // re-enqueue from the transcription path can't double-bill.
        guard inFlight[id] == nil else {
            summarizerLog.log("\(self.shortID(id), privacy: .public): skipped — already in flight")
            return
        }
        let tool = llmSettings.tool
        let executableOverride = llmSettings.executablePath.isEmpty
            ? nil
            : llmSettings.executablePath
        // OpenAI-compatible runs use the endpoint's model name from
        // `llmSettings.openAIModelName`; CLI runs use Live AI's model
        // override. Mirrors `LiveAISession.kick`'s tool-conditional selection
        // (issue celarent7/mila#4 — previously this always sent
        // `liveAISettings.model`, e.g. "claude-sonnet-4-6", to the OpenAI
        // endpoint, which 404'd on model-not-found).
        let model = (tool == .openaiCompatible)
            ? llmSettings.openAIModelName
            : liveAISettings.model
        let extraArgs = llmSettings.extraArgsTokens
        let promptLanguageName: String = {
            switch liveAISettings.outputLanguage {
            case .auto:
                return recording.fullText.isPredominantlyHebrew ? "Hebrew" : "English"
            case .english:
                return "English"
            case .hebrew:
                return "Hebrew"
            }
        }()
        let basePrompt = liveAISettings.summaryPrompt
            .replacingOccurrences(of: "{{LANGUAGE}}", with: promptLanguageName)
        // Wrap the user's plain-text summary prompt so the one-shot call
        // also returns action items. Restores the summary + action-items
        // pair the pre-#87 inline final Live-AI tick used to produce. See
        // `promptWithActionItems`: the summary stays PLAIN TEXT and only a
        // compact item array is JSON, so a long multi-line Hebrew summary
        // full of quotes can't corrupt the parse.
        let prompt = Self.promptWithActionItems(base: basePrompt)
        let transcript = recording.fullText
        let timeout = timeoutSeconds
        // OpenAI-compatible config captured up front so the detached call
        // doesn't depend on `self` (mirrors tool/prompt/etc. above). Summary
        // is free-text, so `jsonMode` is false; `transport` stays nil so the
        // production `URLSession` default applies.
        let openAIBaseURL = llmSettings.openAIBaseURL
        let openAIAPIKey = llmSettings.openAIAPIKey
        let startedAt = Date()
        // Captured strongly: the runner closure holds no reference to
        // `self`, so this can't create a retain cycle, and capturing it
        // here means the call below doesn't depend on `self` still being
        // alive when the LLM returns.
        let runLLM = self.runLLM

        inFlightIDs.insert(id)
        summarizerLog.log("started \(self.shortID(id), privacy: .public) transcript=\(transcript.count, privacy: .public)c force=\(force, privacy: .public)")

        let task = Task { @MainActor [weak self] in
            defer {
                // `return` cannot transfer control out of a defer body in
                // Swift, so an `if let self` block is what we want here
                // rather than an early-return guard. If the summarizer
                // has already deinit'd, there's nothing to clean up —
                // the dictionary and the publisher set went with it.
                if let self {
                    self.inFlight[id] = nil
                    self.inFlightIDs.remove(id)
                    // After each completion, try to pull the next
                    // queued backfill candidate in.
                    self.pumpBackfill()
                }
            }
            do {
                // Routed through the injected `runLLM` seam (defaults to
                // `LLMRunner.run`) so tests can return canned output without
                // spawning a real CLI subprocess.
                let raw = try await runLLM(
                    tool,
                    prompt,
                    transcript,
                    executableOverride,
                    model.isEmpty ? nil : model,
                    extraArgs,
                    timeout,
                    openAIBaseURL,
                    openAIAPIKey,
                    false,
                    nil
                )
                // Split the CLI output into the plain-text summary and the
                // action-items list. `parseSummaryAndItems` handles the
                // sentinel format the prompt asks for, tolerates a model
                // that returned a JSON envelope instead, and — crucially —
                // never surfaces a raw `{...}` blob as the summary when the
                // model emits malformed JSON (unescaped quotes / newlines in
                // a long summary value, which broke the object decode).
                let (summaryText, parsedItems, origin) = Self.parseSummaryAndItems(from: raw)
                guard !summaryText.isEmpty else {
                    // `origin` distinguishes "the CLI printed nothing" from
                    // "the CLI printed a JSON object we could not read a
                    // summary out of" — two very different diagnoses that
                    // used to log identically. It is a fixed keyword, never
                    // the model's text: summary output is derived from the
                    // transcript and is user content, so it must not reach a
                    // `.public` log field (`bugbot-rules/no-user-content-in-logs.md`).
                    summarizerLog.log("skipped \(self?.shortID(id) ?? "?", privacy: .public): no summary parsed origin=\(origin.rawValue, privacy: .public) output=\(raw.count, privacy: .public)c")
                    // No summary landed — let a pending export fall back to
                    // the transcript rather than waiting forever. Skip the
                    // signal entirely if the recording went away mid-flight.
                    if let self, let current = self.liveRecording(id) {
                        self.onSummaryFinished?(current)
                    }
                    return
                }
                // The recording may have been deleted between enqueue
                // and now. Re-fetch so we never write a summary to a
                // ghost row.
                guard let self else { return }
                guard var current = self.store.recordings.first(where: { $0.id == id }) else {
                    summarizerLog.log("skipped \(self.shortID(id), privacy: .public): recording is gone")
                    // Deleted mid-flight — nothing to export, so no signal.
                    return
                }
                let existing = (current.summary ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !force, !existing.isEmpty {
                    summarizerLog.log("skipped \(self.shortID(id), privacy: .public): a summary landed mid-flight")
                    // A summary is present (just from another path) — the
                    // recording is ready to export.
                    self.onSummaryFinished?(current)
                    return
                }
                current.summary = summaryText
                // Replace the recording's action items with the fresh
                // full-transcript set whenever the model returned any — but
                // never at the cost of an item the user DICTATED out loud.
                // An empty list is treated as "keep what's there" so a
                // glitchy empty response can't wipe the rolling live snapshot
                // a Live-AI recording already captured at stop.
                if !parsedItems.isEmpty {
                    current.actionItems = Self.merged(fresh: parsedItems,
                                                      keepingDictatedFrom: current.actionItems ?? [])
                }
                self.store.update(current)
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                summarizerLog.log("succeeded \(self.shortID(id), privacy: .public) origin=\(origin.rawValue, privacy: .public) length=\(summaryText.count, privacy: .public) items=\(current.actionItems?.count ?? 0, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms")
                self.onSummaryFinished?(current)
            } catch {
                summarizerLog.error("failed \(self?.shortID(id) ?? "?", privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Failed generation — signal so a pending export can still
                // write the transcript fallback. A permanent delete cancels
                // the task, which lands here as a CancellationError, so the
                // store lookup is what stops a deleted recording being filed.
                if let self, let current = self.liveRecording(id) {
                    self.onSummaryFinished?(current)
                }
            }
        }
        inFlight[id] = task
    }

    /// Log why a `summarizeIfNeeded` call was rejected. Split out so the
    /// reason ends up in OSLog (and Console.app) with the same
    /// "skipped <id>: <reason>" shape backfill uses.
    private func logSkip(_ recording: Recording, force: Bool) {
        let id = recording.id
        if !llmSettings.summaryEnabled {
            summarizerLog.log("skipped \(self.shortID(id), privacy: .public): auto-summary disabled")
            return
        }
        if !llmSettings.isConfigured {
            summarizerLog.log("skipped \(self.shortID(id), privacy: .public): LLM not configured")
            return
        }
        let transcript = recording.fullText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if transcript.isEmpty {
            summarizerLog.log("skipped \(self.shortID(id), privacy: .public): transcript empty")
            return
        }
        let existing = (recording.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !force, !existing.isEmpty {
            summarizerLog.log("skipped \(self.shortID(id), privacy: .public): already summarized")
            return
        }
    }

    private func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    /// Marker the one-shot prompt asks the model to place between the
    /// plain-text summary and the JSON action-items array. Keeping the
    /// summary OUTSIDE any JSON is deliberate: LLMs routinely emit long,
    /// multi-line summaries with unescaped quotes/newlines, which makes an
    /// enclosing JSON object un-decodable. Only the compact item array — far
    /// less prone to stray quotes — needs to be valid JSON.
    static let actionItemsSentinel = "###ACTION_ITEMS###"

    /// Wrap the user's plain-text summary prompt so the one-shot call also
    /// returns action items, WITHOUT embedding the summary in JSON. The
    /// user's `summaryPrompt` still drives the summary's content and style
    /// (including its `{{LANGUAGE}}` directive); this only appends the
    /// output-format + action-item contract. Building the request here rather
    /// than baking it into the persisted `summaryPrompt` means a user's
    /// customised prompt keeps working and no persisted-default migration is
    /// needed.
    static func promptWithActionItems(base: String) -> String {
        """
        \(base)

        After the summary, list the action items. Format your ENTIRE response \
        exactly like this — the plain-text summary first, then the marker on \
        its own line, then a JSON array:

        <the summary as plain text>
        \(actionItemsSentinel)
        [{"id": "stable-slug", "text": "...", "source": "inferred"}]

        Write the summary as plain text — do NOT wrap it in JSON or quotes. \
        Output the marker \(actionItemsSentinel) verbatim on its own line, then \
        ONLY the JSON array and nothing after it. An action item is a concrete \
        task someone committed to do (with or without a deadline) or an \
        explicit follow-up or request. If there are none, output an empty \
        array: []
        """
    }

    /// Split raw CLI output into `(summary, items, origin)`, where `origin`
    /// names the branch that produced it so the tolerant paths are loggable.
    ///
    /// Resolution order, most-trusted first:
    ///   1. Sentinel format (what `promptWithActionItems` asks for): plain
    ///      summary before `actionItemsSentinel`, JSON array after it.
    ///   2. A JSON envelope `{"summary":...,"items":[...]}` the model may have
    ///      returned out of habit — decoded via `LiveAISession.parseEnvelope`.
    ///   3. Malformed JSON that LOOKS like an envelope (the failure the user
    ///      hit: unescaped quotes broke the object decode). Salvage the
    ///      summary text so a raw `{...}` blob is never shown, and keep any
    ///      items the lenient array parse recovered.
    ///   4. Plain prose — the whole output is the summary, no items.
    ///
    /// A JSON object that reaches step 3 and yields nothing readable returns
    /// an EMPTY summary rather than the blob — see `unreadableEnvelope`.
    static func parseSummaryAndItems(
        from raw: String
    ) -> (summary: String, items: [ActionItem], origin: SummaryParseOrigin) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sentinel = trimmed.range(of: actionItemsSentinel) {
            let summary = String(trimmed[..<sentinel.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let items = LiveAISession.parseActionItems(from: String(trimmed[sentinel.upperBound...]))
            return (summary, items, .sentinel)
        }
        // No sentinel — the model returned a JSON envelope (or prose).
        let parsed = LiveAISession.parseEnvelope(from: trimmed)
        if !parsed.summary.isEmpty {
            return (parsed.summary, parsed.items, .envelope)
        }
        // Object decode produced no summary. If it still looks like an
        // envelope, salvage the summary value rather than surfacing the blob.
        if trimmed.hasPrefix("{") {
            let salvaged = Self.salvageSummaryValue(from: trimmed)
            if !salvaged.isEmpty {
                return (salvaged, parsed.items, .salvagedEnvelope)
            }
            // A JSON object we cannot read a summary out of at all (no
            // `"summary"` key, or an empty one). Storing it verbatim is the
            // exact bug this fix exists to remove, and doing so is
            // self-perpetuating: a stored blob satisfies `shouldSummarize`'s
            // "already has a summary" gate, so the recording would never be
            // retried and the blob would be what the detail view, the Obsidian
            // note and the MCP surface all report forever. Report NO summary
            // instead — logged with this origin at the call site, exported as
            // the transcript fallback, and still picked up by the next
            // `backfillIfNeeded` sweep. That is the same treatment empty CLI
            // output has always had (`test_summarize_drops_empty_output`), so
            // it is an established shape rather than a new one. Items the
            // lenient array parse recovered are still returned.
            return ("", parsed.items, .unreadableEnvelope)
        }
        return (trimmed, [], .plain)
    }

    /// Which branch of `parseSummaryAndItems` produced the result. Logged so
    /// the tolerant paths are VISIBLE — a model that quietly ignores the
    /// output contract on every call should be diagnosable from Console
    /// instead of hiding behind a summary that looks fine.
    ///
    /// A fixed keyword, deliberately: the model's output is derived from the
    /// user's transcript and is user content, so it must never reach a
    /// `.public` log field (`bugbot-rules/no-user-content-in-logs.md`). This
    /// records WHICH SHAPE arrived, never what it said.
    enum SummaryParseOrigin: String {
        /// The sentinel format `promptWithActionItems` asks for.
        case sentinel
        /// A decodable `{"summary":…,"items":[…]}` envelope.
        case envelope
        /// A broken envelope whose summary value was recovered textually.
        case salvagedEnvelope = "salvaged-envelope"
        /// Plain prose — the whole output is the summary.
        case plain
        /// A JSON object with no readable summary. Yields no summary at all.
        case unreadableEnvelope = "unreadable-envelope"
    }

    /// Fold the fresh full-transcript items into what the recording already
    /// has, keeping every item the user DICTATED (`source == .voiceCommand`,
    /// i.e. "Mila, action item: …") ahead of the model's inferred set.
    ///
    /// Why this is not a plain replace: for a Live-AI recording,
    /// `QuickActionsController` snapshots the live list — voice-command items
    /// included — onto the recording at stop and then immediately calls
    /// `regenerate`. The one-shot prompt is not shown the existing list and
    /// only ever asks for `source: "inferred"`, so a wholesale replace would
    /// trade an item the user said out loud for the model's guess at it, or
    /// lose it entirely. `ActionItem.source` is also mirrored all the way out
    /// to the MCP surface precisely so a client can tell a spoken commitment
    /// from an inferred one (see `MilaKit.StoredRecording.ActionItem.source`),
    /// which is the answer this would have degraded.
    ///
    /// Fresh items are deduped by id and by normalised text — the model
    /// re-derives a dictated task from the transcript under a new id, and it
    /// also duplicates ids outright, which the live path already guards
    /// against ("LLM duplicated an id; keep first" in
    /// `LiveAISession.applyResponse`).
    static func merged(fresh: [ActionItem],
                       keepingDictatedFrom existing: [ActionItem]) -> [ActionItem] {
        let dictated = existing.filter { $0.source == .voiceCommand }
        var seenIDs = Set(dictated.map(\.id))
        var seenTexts = Set(dictated.map { Self.dedupKey($0.text) })
        var result = dictated
        for item in fresh {
            let textKey = Self.dedupKey(item.text)
            guard !seenIDs.contains(item.id), !seenTexts.contains(textKey) else { continue }
            seenIDs.insert(item.id)
            seenTexts.insert(textKey)
            result.append(item)
        }
        return result
    }

    /// Normalised form used only to spot "the model re-emitted this dictated
    /// item under a different id": trimmed, case-folded, inner whitespace
    /// collapsed. Never persisted or displayed.
    private static func dedupKey(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Best-effort extraction of the `"summary"` value from a JSON string the
    /// decoder rejected (typically because the value itself contains
    /// unescaped `"`). Anchors on the structural `"items"` key that follows
    /// the summary value, so quotes INSIDE the summary don't cut it short,
    /// then un-escapes the common JSON escapes so `\n` renders as newlines.
    static func salvageSummaryValue(from json: String) -> String {
        guard let keyRange = json.range(of: "\"summary\"") else { return "" }
        let afterKey = json[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return "" }
        let afterColon = afterKey[afterKey.index(after: colon)...]
        guard let openQuote = afterColon.firstIndex(of: "\"") else { return "" }
        let valueStart = afterColon.index(after: openQuote)
        let rest = afterColon[valueStart...]
        let endIdx: Substring.Index
        // Find the `"items"` KEY, then walk back to the last quote before it:
        // that quote is the summary value's terminator whatever separates the
        // two. Matching the separator literally (`", "items"` / `","items"`)
        // only covered compact output — a pretty-printed malformed envelope
        // (`",\n  "items"`, which is what a CLI emitting multi-line JSON
        // produces) fell through to `lastIndex(of:)` and dragged the entire
        // items array into the summary, i.e. exactly the scaffolding leak
        // this function exists to prevent.
        if let itemsKey = rest.range(of: "\"items\"") {
            let head = rest[..<itemsKey.lowerBound]
            endIdx = head.lastIndex(of: "\"") ?? itemsKey.lowerBound
        } else if let lastQuote = rest.lastIndex(of: "\"") {
            endIdx = lastQuote
        } else {
            endIdx = rest.endIndex
        }
        let value = String(rest[..<endIdx])
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\/", with: "/")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The freshest copy of a recording from the store, or `fallback` when
    /// it's no longer there. Used by the SYNCHRONOUS skip paths, where the
    /// caller handed us the recording a moment ago and the fallback is the
    /// same object it already holds.
    private func latestRecording(_ id: UUID, fallback: Recording) -> Recording {
        store.recordings.first(where: { $0.id == id }) ?? fallback
    }

    /// The recording as the store currently holds it, or nil when it's gone.
    /// Used by the ASYNCHRONOUS completion paths, where a delete can land
    /// between enqueue and completion: firing with the stale enqueue-time copy
    /// would let an observer act on a row the user just deleted.
    private func liveRecording(_ id: UUID) -> Recording? {
        store.recordings.first(where: { $0.id == id })
    }
}
