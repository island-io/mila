import Foundation
import Combine
import OSLog
import MilaKit

private let postRecordingLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                      category: "PostRecordingCoordinator")

/// Owns the "Name this recording" sheet lifecycle. The sheet pops the moment
/// a recording is added (i.e. recording stopped) — NOT when transcription
/// finishes — so the user can already type a title while Whisper is still
/// chewing on the audio. The sheet watches the store for the transcript and
/// enables LLM-driven suggest / send buttons once the text is available.
@MainActor
final class PostRecordingCoordinator: ObservableObject {
    /// The recording the rename sheet is currently bound to, if any.
    @Published var pending: Recording?

    /// One-shot status messages from background LLM actions ("Sent to
    /// Claude", "Send to Cursor failed: …"). ContentView renders these as a
    /// brief banner.
    @Published var activityStatus: String?
    @Published var activityIsError: Bool = false

    /// Recordings whose title is currently being suggested by the background
    /// auto-suggest job. The rename sheet reads this to show a "suggesting…"
    /// affordance without owning the work itself.
    @Published private(set) var autoSuggestingIDs: Set<UUID> = []

    private let store: RecordingStore
    private let transcription: TranscriptionService
    private let llm: LLMSettings

    /// Injectable LLM-run seam so tests can assert what `PostRecordingCoordinator`
    /// sends to `LLMRunner` (e.g. that the OpenAI path threads `openAIModelName`
    /// — issue celarent7/mila#3) without spawning a CLI or hitting the network.
    /// Mirrors `RecordingSummarizer.RunLLM`, including its `@MainActor` isolation,
    /// so test stubs that capture/mutate main-actor variables stay data-race-clean
    /// under Swift 6 strict concurrency (CodeRabbit #7). Defaults to `LLMRunner.run`.
    typealias RunLLM = @MainActor (
        _ tool: LLMTool,
        _ prompt: String,
        _ transcript: String,
        _ summary: String,
        _ executablePathOverride: String?,
        _ model: String?,
        _ extraArgs: [String],
        _ timeout: TimeInterval,
        _ openAIBaseURL: String?,
        _ openAIAPIKey: String?,
        _ jsonMode: Bool,
        _ transport: OpenAITransport?,
        // Which surface this call is for — the auto-title path and the Send
        // path share this one seam, so the label has to come from the call
        // site or the log can't tell them apart (issue #175).
        _ feature: LLMFeature,
        // Inline the transcript body, or name the recording's sidecars and let
        // the CLI read them (issue #179). Only the Send path ever asks for
        // `.reference`; the auto-title path passes `.inline`.
        _ delivery: TranscriptDelivery
    ) async throws -> String
    private let runLLM: RunLLM

    /// LLM work spawned from inside the rename sheet (manual Suggest) plus
    /// the background auto-suggest job. Tracked here — not in the sheet's view
    /// state — so the Cancel button can kill it even after the sheet is
    /// torn down, and so the in-flight handle survives the SwiftUI redraws
    /// that would otherwise re-create local `@State`.
    private var llmTasks: [UUID: Task<Void, Never>] = [:]

    /// Background "Send to <LLM>" work, keyed per-recording. Owned here —
    /// on the app-lifetime coordinator — rather than spawned as a bare
    /// anonymous `Task.detached` from the sheet, so the call survives the
    /// sheet being dismissed (the whole point of "fire and walk away") and
    /// so `cancelAndDiscard` can cancel it before deleting the recording.
    ///
    /// Separate from `llmTasks` (the foreground / auto Suggest path) so a
    /// manual Suggest and a background Send for the same recording don't
    /// clobber each other's handle. Mirrors `RecordingSummarizer.inFlight`:
    /// id-keyed, self-clearing on completion, re-send for the same id
    /// cancels + replaces the prior one.
    private var sendTasks: [UUID: Task<Void, Never>] = [:]

    /// How long the background send will wait for an as-yet-unfinished
    /// transcript before giving up. "Send to Claude" can now be pressed
    /// before transcription finishes (fire and walk away), so when the
    /// caller hands us an empty transcript we poll the store until the
    /// recording lands in a terminal state. Generous bound: a long file
    /// can still be transcribing minutes after the user walks away.
    var transcriptWaitTimeout: TimeInterval = 600

    init(store: RecordingStore,
         transcription: TranscriptionService,
         llm: LLMSettings,
         runLLM: @escaping RunLLM = { tool, prompt, transcript, summary, executablePathOverride, model, extraArgs, timeout, openAIBaseURL, openAIAPIKey, jsonMode, transport, feature, delivery in
        try await LLMRunner.run(
            tool: tool,
            prompt: prompt,
            transcript: transcript,
            summary: summary,
            delivery: delivery,
            executablePathOverride: executablePathOverride,
            model: model,
            extraArgs: extraArgs,
            timeout: timeout,
            openAIBaseURL: openAIBaseURL,
            openAIAPIKey: openAIAPIKey,
            jsonMode: jsonMode,
            transport: transport,
            feature: feature)
    }) {
        self.store = store
        self.transcription = transcription
        self.llm = llm
        self.runLLM = runLLM
    }

    /// Open the rename sheet for a freshly-added recording. Called by
    /// QuickActionsController right after `store.add(...)`. Idempotent: if
    /// the sheet is already showing a different recording the new one is
    /// dropped (we don't queue — concurrent voice memos are rare and a
    /// stack of sheets is worse UX than just naming the first one).
    func present(_ recording: Recording) {
        // UI-TEST: the record-while-finalizing E2E drives two back-to-back
        // recordings through the real `stopRecording`; a modal rename sheet
        // after each Stop would sit over Home and block the next Record tap
        // / the button-state query. Suppress it under the regression flag —
        // the recording is still added to the store (the assertion target),
        // it just isn't surfaced for renaming. No effect on any real launch.
        if CommandLine.arguments.contains("--ui-test-finalize-regression") { return }
        guard pending == nil else { return }
        pending = recording
        armAutoSuggestTitle(for: recording)
    }

    // MARK: - Background auto-suggest title

    /// Kick off background title suggestion for a freshly-added recording.
    ///
    /// This is deliberately decoupled from the rename sheet: the LLM CLI can
    /// take a long time to answer, and the old in-sheet path lost the result
    /// the moment the user hit Save (the suggestion landed in discarded
    /// `@State`). Running it here means the user can Save and move on
    /// immediately — the title is written to the saved recording whenever the
    /// CLI returns, as long as the user hasn't given it their own title in
    /// the meantime. (Issue #34.)
    ///
    /// The transcript is usually still being finalized at add time, so we
    /// reuse `awaitTranscript` (the same poller "Send to <LLM>" uses) to wait
    /// for it before invoking the CLI.
    private func armAutoSuggestTitle(for recording: Recording) {
        guard llm.isConfigured, llm.nameGenerationEnabled else { return }
        let id = recording.id
        // The default, machine-generated title at add time. We only apply an
        // AI suggestion later if the recording STILL carries this title —
        // i.e. the user hasn't renamed it (in the sheet or the list).
        let baselineTitle = recording.title
        let tool = llm.tool
        let prompt = llm.namePrompt
        let executableOverride = llm.executablePath.isEmpty ? nil : llm.executablePath
        let cliTimeout = llm.cliTimeout
        let openAIBaseURL = llm.openAIBaseURL
        let openAIAPIKey = llm.openAIAPIKey
        // OpenAI-compatible runs need the model name threaded explicitly
        // (the CLIs pick their own; the HTTP path can't). Captured up front
        // like the other OpenAI fields so the detached call doesn't touch
        // `self.llm` (issue celarent7/mila#3 — otherwise the request POSTs
        // an empty model name and the suggestion fails silently).
        let openAIModelName = llm.openAIModelName
        let openAIModel: String? = (tool == .openaiCompatible && !openAIModelName.isEmpty)
            ? openAIModelName : nil
        let waitTimeout = transcriptWaitTimeout
        autoSuggestingIDs.insert(id)
        let task = Task { @MainActor [weak self] in
            defer {
                self?.autoSuggestingIDs.remove(id)
                // Only relinquish the tracked-task slot if we finished on our
                // own. If we were cancelled it's because a replacement task
                // (manual Suggest) or `cancelAndDiscard` took over the slot —
                // clearing it here would orphan their handle.
                if !Task.isCancelled { self?.clearLLM(for: id) }
            }
            guard let self else { return }
            guard let transcript = await self.awaitTranscript(for: id,
                                                              timeout: waitTimeout) else {
                return  // discarded, timed out, or empty transcript
            }
            if Task.isCancelled { return }
            do {
                let suggestion = try await runLLM(
                    tool,
                    prompt,
                    transcript,
                    "",                       // summary — title path has none
                    executableOverride,
                    openAIModel,
                    [],                       // extraArgs — title path has none
                    cliTimeout,
                    openAIBaseURL,
                    openAIAPIKey,
                    false,
                    nil,
                    .name,
                    // Titles stay inlined. Path delivery is scoped to the
                    // Send action (issue #179): this path runs unattended on
                    // every recording, so a CLI that skipped the read would
                    // quietly title everything from a prompt with no
                    // transcript in it, and nobody would notice.
                    .inline)
                if Task.isCancelled { return }
                let title = Self.cleanedTitle(from: suggestion)
                guard !title.isEmpty else { return }
                self.applyAutoSuggestedTitle(title, to: id, baseline: baselineTitle)
            } catch {
                // Best-effort, background work — swallow. (Cancellation fires
                // here too when the user Discards or manually re-Suggests.)
            }
        }
        trackLLM(task, for: id)
    }

    /// Apply a background suggestion to the stored recording, but never
    /// clobber a title the user chose themselves — if the recording's title
    /// has diverged from the baseline default, the user (or a manual Suggest)
    /// already named it and wins.
    private func applyAutoSuggestedTitle(_ title: String, to id: UUID, baseline: String) {
        guard var recording = store.recordings.first(where: { $0.id == id }),
              recording.title == baseline,
              recording.title != title else { return }
        recording.title = title
        store.update(recording)
    }

    /// Extract a bare title from raw CLI output: trim surrounding quotes /
    /// punctuation and keep only the first non-empty line (some CLIs add
    /// commentary even when asked for just a title).
    static func cleanedTitle(from raw: String) -> String {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`."))
        let firstLine = cleaned.split(whereSeparator: \.isNewline)
            .first.map(String.init) ?? cleaned
        return firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`. "))
    }

    /// Persist a user-supplied title and dismiss. `nil` / blank title means
    /// "keep whatever's there".
    func dismiss(savingTitle newTitle: String? = nil) {
        if let recording = pending,
           let trimmed = newTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !trimmed.isEmpty,
           var updated = store.recordings.first(where: { $0.id == recording.id }),
           trimmed != updated.title {
            updated.title = trimmed
            store.update(updated)
        }
        pending = nil
    }

    /// Register a background LLM task so a later Cancel can cancel it. Any
    /// previously-tracked task for the same recording is replaced (and
    /// cancelled — there's no use case for two LLM calls competing for the
    /// same sheet).
    func trackLLM(_ task: Task<Void, Never>, for recordingID: UUID) {
        llmTasks[recordingID]?.cancel()
        llmTasks[recordingID] = task
    }

    /// Forget the tracked LLM task for `recordingID` without cancelling it.
    /// Called when the task ran to completion on its own, so we don't hold
    /// on to dead handles.
    func clearLLM(for recordingID: UUID) {
        llmTasks[recordingID] = nil
    }

    // MARK: - Background "Send to <LLM>"

    /// True while a background send is in flight for `recordingID`. Lets
    /// the rename sheet (or any caller) reflect "still sending" state.
    func isSending(_ recordingID: UUID) -> Bool {
        sendTasks[recordingID] != nil
    }

    /// Fire the configured LLM action against `recordingID` in the
    /// background and report the result through the activity banner.
    ///
    /// This is the shared implementation behind the rename sheet's
    /// "Send to <LLM>" button and the right-click "Send to <LLM>…"
    /// sheet. Both snapshot their prompt / transcript / summary and
    /// dismiss BEFORE calling this, so the call genuinely runs in the
    /// background — the user can close the sheet and walk away.
    ///
    /// `transcript` is whatever the caller had at click time. When the
    /// user fires before transcription finishes it'll be empty; in that
    /// case we wait for the recording to reach a terminal state and pull
    /// the finished transcript out of the store ourselves, rather than
    /// blocking the UI behind a disabled button. (The sheet used to gate
    /// the button on `transcriptReady` for exactly this reason — now the
    /// readiness wait lives here so "Send" is always pressable.)
    ///
    /// Idempotent per id: a second send for the same recording cancels and
    /// replaces the first (no use case for two competing CLI calls writing
    /// the same banner). The task clears its own handle on completion.
    ///
    /// When `LLMSettings.actionDeliversTranscriptByPath` is on, the composed
    /// prompt names the recording's `.srt` / `.txt` / audio files instead of
    /// carrying the transcript body (issue #179). `transcript` is still
    /// resolved and passed either way — it is the fallback when no sidecar
    /// exists yet.
    func sendToLLM(recordingID: UUID,
                   tool: LLMTool,
                   prompt: String,
                   transcript: String,
                   summary: String,
                   executableOverride: String?,
                   extraArgs: [String] = [],
                   cliTimeout: TimeInterval = LLMRunner.defaultTimeout) {
        guard tool != .none else { return }
        let toolName = tool.displayName

        // Cancel + replace any prior send for this recording.
        sendTasks[recordingID]?.cancel()

        postStatus("Sending to \(toolName)…")

        let timeout = transcriptWaitTimeout
        // Capture the OpenAI endpoint config at click time. The Task below may
        // wait on `awaitTranscript` (potentially long) before reading endpoint
        // values; reading `self.llm` inside it would pair a mid-flight Settings
        // edit with the click-time `tool`/`prompt`. Snapshot up front instead —
        // mirrors `armAutoSuggestTitle` (CodeRabbit #8, issue celarent7/mila#8).
        let openAIBaseURL = llm.openAIBaseURL
        let openAIAPIKey = llm.openAIAPIKey
        let openAIModelName = llm.openAIModelName
        // Whether to reference the transcript by path (issue #179) is a
        // click-time snapshot for the same reason the endpoint fields are: the
        // Task below can sit in `awaitTranscript` for minutes, and a Settings
        // edit landing in that window must not repaint this send. The *paths*
        // are resolved later, inside the Task — they only exist once
        // transcription has written them.
        let byPath = llm.actionDeliversTranscriptByPath
        let task = Task { @MainActor [weak self] in
            defer {
                // Only relinquish the slot if we finished on our own. If we
                // were cancelled, a replacement send (or `cancelAndDiscard`)
                // took over the slot — clearing it here would orphan the
                // replacement's handle (isSending would go false mid-flight
                // and a later cancel couldn't reach it).
                if let self, !Task.isCancelled { self.sendTasks[recordingID] = nil }
            }
            guard let self else { return }
            // Resolve the transcript: use the click-time snapshot if it
            // already has text, otherwise wait for transcription to finish.
            let resolved: String
            if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let waited = await self.awaitTranscript(for: recordingID,
                                                              timeout: timeout) else {
                    if Task.isCancelled { return }
                    self.postStatus("\(toolName): no transcript to send.", isError: true)
                    return
                }
                resolved = waited
            } else {
                resolved = transcript
            }
            if Task.isCancelled { return }
            do {
                // OpenAI-compatible runs need the model name threaded (the
                // HTTP path can't pick its own). Issue celarent7/mila#3.
                // `openAIModelName`/`openAIBaseURL`/`openAIAPIKey` are the
                // click-time captures from above (#8).
                let openAIModel: String? = (tool == .openaiCompatible && !openAIModelName.isEmpty)
                    ? openAIModelName : nil
                let output = try await runLLM(
                    tool,
                    prompt,
                    resolved,
                    summary,
                    executableOverride,
                    openAIModel,
                    extraArgs,
                    cliTimeout,
                    openAIBaseURL,
                    openAIAPIKey,
                    false,
                    nil,
                    .action,
                    // Resolved here, after the transcript wait: the `.srt` is
                    // written at the end of the transcription pass, so asking
                    // any earlier would find nothing and fall back to inline
                    // for every send fired mid-recording.
                    byPath ? self.transcriptReferences(for: recordingID) : .inline)
                let preview = output
                    .replacingOccurrences(of: "\n", with: " ")
                    .prefix(80)
                self.postStatus("\(toolName): \(preview)")
                postRecordingLog.log("send succeeded \(recordingID.uuidString.prefix(8), privacy: .public) -> \(output.count, privacy: .public) chars")
            } catch LLMRunnerError.cancelled {
                // User discarded the recording (or fired a replacement
                // send) — no banner, the cancellation was deliberate.
            } catch {
                if Task.isCancelled { return }
                self.postStatus("\(toolName) failed: \(error.localizedDescription)",
                                isError: true)
                postRecordingLog.error("send failed \(recordingID.uuidString.prefix(8), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        sendTasks[recordingID] = task
    }

    /// The recording's own sidecars, as a `.reference` delivery (issue #179).
    ///
    /// Nothing is written here: `.srt`, `.txt` and the audio are files
    /// `TranscriptionService` / `RecordingStore` already maintain next to each
    /// other in the recordings directory, and `TranscriptFiles.existing` drops
    /// any of them that isn't on disk with bytes in it. So the mode adds no new
    /// copy of the user's transcript anywhere — in particular not into the
    /// shared `llm-sandbox` cwd (#187), which every later invocation is also
    /// chdir'd into and would therefore be able to read (the concern open in
    /// #190).
    ///
    /// Returns `.reference` with an empty set when nothing exists yet;
    /// `LLMRunner.effectiveDelivery` turns that back into `.inline`, so the
    /// worst case is today's behaviour rather than a prompt pointing nowhere.
    private func transcriptReferences(for recordingID: UUID) -> TranscriptDelivery {
        guard let rec = store.recordings.first(where: { $0.id == recordingID }) else {
            return .inline
        }
        return .reference(.existing(subtitles: store.subtitleURL(for: rec),
                                    plainText: store.transcriptURL(for: rec),
                                    audio: store.audioURL(for: rec)))
    }

    /// Poll the store until `recordingID` has a non-empty transcript and
    /// has left the in-progress states (`.pending` / `.running`), then
    /// return the speaker-aware plain text. Returns nil if the recording
    /// disappears, ends up with no text, or the wait times out / is
    /// cancelled. The wait is cheap (a short sleep between checks) and
    /// honours task cancellation so `cancelAndDiscard` unblocks it
    /// immediately.
    private func awaitTranscript(for recordingID: UUID,
                                 timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return nil }
            guard let rec = store.recordings.first(where: { $0.id == recordingID }) else {
                return nil  // discarded out from under us
            }
            if rec.status != .pending && rec.status != .running {
                let text = TranscriptFormatter.plainText(segments: rec.segments,
                                                         fallback: rec.fullText,
                                                         names: rec.speakerNames)
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : text
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    /// The Cancel button in the rename sheet: throw away EVERYTHING related
    /// to this recording. The user's mental model is "I changed my mind" —
    /// transcription that's still running keeps burning CPU on a result they
    /// won't see, and the foreground/background LLM call keeps running
    /// against the user's CLI auth quota. So:
    ///  1. cancel any in-flight LLM task — both the foreground Suggest
    ///     task AND the background Send task — terminating the underlying
    ///     CLI process via LLMRunner's task-cancellation handler. (Without
    ///     cancelling the Send task, Discard could delete the recording out
    ///     from under an in-flight send, leaving a CLI call chewing on a
    ///     transcript whose recording no longer exists.)
    ///  2. trip the transcription service's abort flag so whisper.cpp
    ///     unwinds within ~100ms instead of finishing
    ///  3. permanently delete the recording + its audio file
    ///  4. dismiss the sheet
    func cancelAndDiscard() {
        guard let recording = pending else { pending = nil; return }
        autoSuggestingIDs.remove(recording.id)
        if let task = llmTasks.removeValue(forKey: recording.id) {
            task.cancel()
        }
        if let task = sendTasks.removeValue(forKey: recording.id) {
            task.cancel()
        }
        transcription.cancel(recordingID: recording.id)
        if let stored = store.recordings.first(where: { $0.id == recording.id }) {
            store.permanentlyDelete(stored)
        }
        pending = nil
    }

    /// Set a transient status message visible to the user. Auto-clears
    /// after a few seconds.
    func postStatus(_ message: String, isError: Bool = false) {
        activityStatus = message
        activityIsError = isError
        let snapshot = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            if self.activityStatus == snapshot {
                self.activityStatus = nil
                self.activityIsError = false
            }
        }
    }
}
