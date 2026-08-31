import Foundation
import Combine
import OSLog
import TranscriptionCore

private let serviceLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "TranscriptionService")

// MARK: - Logging privacy in this file
//
// Every line the transcription pass emits used to be a `print`, and a `print`
// is public by construction — it has no privacy annotation, and an app
// launched by launchd has its stdio captured into the unified log regardless.
// The pass is also the highest-volume producer of these lines: one set per
// recording, forever.
//
// `recording.title` is a meeting name — "Q3 board call", a client, a
// candidate's name — and it was interpolated into roughly fourteen of them.
// So the rule here, the one PR #183 settled for `RecordingStore`:
//
//   * the recording's UUID is the PUBLIC correlation key. It carries no
//     content, and it is what lets you follow one recording across the queue,
//     the run and the failure.
//   * the title, and any filename derived from it, are `.private`. Audio,
//     transcript, summary and subtitle names all come from the title via
//     `RecordingStore.freshAudioURL(suggestedName:)` / `FileTranscriber`'s
//     `safeStem`, so logging a filename logs a title.
//   * an `error`'s message is `.private` wherever the failure touched one of
//     those files, because Cocoa quotes the offending file — and its
//     containing folder — inside `localizedDescription`. `NSError.domain` and
//     `code` stay public: they are what separates "no permission" from a full
//     disk, and they name nothing.
//   * everything that is model/engine/queue state — model names, sample
//     counts, segment counts, speaker counts, durations — stays `.public`.
//     Redacting those would make a real failure undiagnosable and protect
//     nothing.
//
// (Issue #213, CWE-532.)

/// Coordinates batch transcription of recordings + one-shot transcription
/// for dictation.
///
/// Recording transcriptions go through a strict FIFO queue: only one runs at
/// a time, with `activeRecordingID` and `progress` tied to whichever job is
/// actually executing. Concurrent enqueues land in `pendingIDs` until their
/// turn, instead of fighting for the same UI state slot.
@MainActor
final class TranscriptionService: ObservableObject {
    @Published private(set) var activeRecordingID: UUID?
    @Published private(set) var pendingIDs: [UUID] = []

    /// Set to a recording's id while the OFFLINE speaker re-diarize pass is
    /// running for it (`rediarizeSegments`). This is NOT transcription —
    /// the transcript text is already final by this point; the pyannote
    /// subprocess is only re-clustering speaker labels. The UI uses this to
    /// show an accurate "Identifying speakers…" status instead of falsely
    /// implying the transcript is still being produced. `nil` when no
    /// re-diarize is in flight.
    @Published private(set) var diarizingRecordingID: UUID?
    @Published private(set) var progress: Double = 0
    @Published var lastError: String?

    /// True while the underlying whisper engine is doing a "noticeable"
    /// first-time load — currently means a sibling `-encoder.mlmodelc`
    /// is being compiled by CoreML for this device (~13s on M-series
    /// the very first time). The engine notifies us via a callback;
    /// we bridge to `@MainActor` so SwiftUI views can gate the Record
    /// button on this state. See `HomeView`'s preparation banner.
    @Published private(set) var isPreparingModel: Bool = false

    /// Human-readable status string the engine wants the UI to show
    /// alongside the spinner ("Preparing Neural Engine…"). `nil` when
    /// not preparing or when the engine didn't supply one.
    @Published private(set) var preparationStatus: String?

    /// Audio shorter than this is treated as "no recording" — Whisper happily
    /// hallucinates confident transcripts from sub-100ms noise.
    static let minimumAudioDurationSeconds: Double = 0.3
    /// Audio whose peak sample is below this is treated as silence. The
    /// auto-gain in WhisperEngine.normalize() would otherwise amplify it
    /// to clipping levels and produce ghost transcripts.
    static let minimumAudioPeak: Float = 0.005

    /// Shown when capture produced no samples at all — the microphone's
    /// problem, surfaced as the microphone's problem. See the guard in
    /// `transcribeOnceSegments`.
    static let noAudioCapturedMessage = "No audio was captured, so there was nothing to transcribe. Check System Settings ▸ Privacy & Security ▸ Microphone, and that the input selected in Settings ▸ Audio Input isn't muted, disconnected, or in use by another app."

    private let engine: any TranscribingEngine
    private let store: RecordingStore
    private let modelManager: ModelManager
    private let diarizationSettings: DiarizationSettings

    /// User's transcription backend choice (on-device vs remote API). When the
    /// remote backend is active + configured, transcription is routed through
    /// `remoteEngine` instead of the local whisper.cpp `engine`, and the
    /// local-model install gate is skipped (a remote user may have no `.bin`
    /// downloaded at all).
    private let remoteSettings: RemoteTranscriptionSettings

    /// OpenAI-compatible remote engine. Constructed unconditionally but only
    /// exercised when `remoteSettings.isActive` — cheap to hold idle (no
    /// weights, just a URLSession). Injectable so tests can substitute an
    /// engine that fails deterministically (see `RemoteTranscribing`).
    private let remoteEngine: any RemoteTranscribing

    /// Hook fired once per recording that finished transcription
    /// successfully (status == .completed, non-empty text). MilaApp
    /// wires this to `RecordingSummarizer.summarizeIfNeeded` so every
    /// completed recording auto-generates a summary when the LLM CLI
    /// is configured — independent of whether Live AI mode was on
    /// during the recording. The hook lives here (rather than inside
    /// the summarizer subscribing to store changes) so it fires
    /// exactly once per transcription, NOT on every subsequent
    /// `store.update` that touches the same recording.
    ///
    /// The second argument is `true` when the recording already had a
    /// non-empty `summary` at the moment the transcription started —
    /// i.e. the user explicitly re-transcribed an already-finished
    /// recording. Callers use that signal to force-regenerate the
    /// summary (the old one now refers to a transcript that no longer
    /// exists). For first-time transcription it's `false`.
    var onTranscriptionCompleted: ((Recording, _ wasRetranscription: Bool) -> Void)?

    /// Auto-drop gate for accidental short+empty captures (issue #61). Wired
    /// by `MilaApp` to the user's `recordings.minDuration` threshold. Given a
    /// just-finished recording's duration + transcript, returns `true` when
    /// the clip should be dropped — i.e. it's BOTH shorter than the threshold
    /// AND has no transcript (a hotkey misfire / silence). Short clips that
    /// DID produce text, and anything at/over the threshold, return `false`
    /// (kept). `nil` — the default, used by every test that doesn't opt in —
    /// means "never drop", so transcription behaviour is unchanged unless the
    /// app explicitly wires the gate.
    var shouldAutoDropShortEmpty: ((_ duration: Double, _ transcript: String) -> Bool)?

    private var queue: [Recording] = []
    private var worker: Task<Void, Never>?

    /// Recordings the user asked to abandon mid-run. Held in a thread-safe
    /// box because whisper.cpp's `abort_callback` polls this from a
    /// background compute thread, while writes (`cancel(_:)`) come from
    /// `@MainActor`. Without the lock, the cross-actor read would be a
    /// data race under strict concurrency.
    private let cancellation = CancellationFlag()

    /// Tracks the in-flight observer registration. Held so the prewarm
    /// path can `await` it before kicking off the first `loadIfNeeded`
    /// — without that gate, an early prewarm could begin compiling the
    /// CoreML encoder before the observer is installed on the engine
    /// actor, and `isPreparingModel` would never flip to `true`. The
    /// Record button would stay enabled and the user could start a
    /// recording while the encoder was still cold (PR #32 / Bugbot #3).
    ///
    /// Lazily assigned at the end of `init` — implicitly-unwrapped so
    /// we don't need a pre-init placeholder Task.
    private var observerSetupTask: Task<Void, Never>!

    init(store: RecordingStore,
         modelManager: ModelManager,
         diarizationSettings: DiarizationSettings,
         remoteSettings: RemoteTranscriptionSettings? = nil,
         engine: any TranscribingEngine = WhisperEngine(),
         remoteEngine: (any RemoteTranscribing)? = nil) {
        self.store = store
        self.modelManager = modelManager
        self.diarizationSettings = diarizationSettings
        // Default constructed inside this @MainActor init (a default argument
        // can't, since those evaluate in a nonisolated context). Tests that
        // don't exercise the remote path simply omit it.
        self.remoteSettings = remoteSettings ?? RemoteTranscriptionSettings()
        self.engine = engine
        self.remoteEngine = remoteEngine ?? RemoteWhisperEngine()
        // Bridge the engine's preparation callback onto the main
        // actor so SwiftUI subscribers see flips through `@Published`
        // (which is itself MainActor-isolated). The closure is
        // `@Sendable` because the engine actor invokes it from its
        // own context.
        //
        // Capture the registration Task so `prewarm` (and any other
        // entry point that calls `loadIfNeeded`) can await it before
        // touching the engine. The engine actor would serialize calls
        // FIFO anyway, but Task scheduling order between this Task
        // and the prewarm Task is undefined — without the explicit
        // await in those call sites, the first CoreML compile could
        // fire before this observer landed.
        let serviceRef = self
        self.observerSetupTask = Task { [engine] in
            await engine.setPreparationObserver { [weak serviceRef] preparing, status in
                Task { @MainActor in
                    guard let serviceRef else { return }
                    serviceRef.isPreparingModel = preparing
                    serviceRef.preparationStatus = preparing ? status : nil
                }
            }
        }
    }

    // MARK: - Prewarm

    /// Pre-load the user's default model in a detached task. Called
    /// once at app launch so the first-ever CoreML compile (~13s on
    /// M-series) happens BEFORE the user taps Record. Without this,
    /// pressing Record during the compile window produces a recording
    /// that yields `segments=0` because the encoder isn't ready yet.
    ///
    /// Failures are silent — the actual transcription path will retry
    /// `loadIfNeeded` and surface any real error there. Best-effort.
    ///
    /// `language` defaults to the user's persisted recording language;
    /// callers pass in their `RecordingLanguageSettings.current` so we
    /// pick the model the next recording is most likely to want.
    func prewarm(language: String) {
        guard let model = modelManager.model(for: language),
              modelManager.isInstalled(model) else {
            serviceLog.log("prewarm: skipping — no installed model for lang=\(language, privacy: .public)")
            return
        }
        let modelURL = modelManager.url(for: model)
        let displayName = model.displayName
        // Capture as non-optional — `observerSetupTask` is implicitly
        // unwrapped on the property but force-imports here would
        // re-promote it to Optional inside the closure.
        let observerTask: Task<Void, Never> = observerSetupTask
        serviceLog.log("prewarm: kicking off load for \(displayName, privacy: .public)")
        Task.detached(priority: .userInitiated) { [engine] in
            // Bugbot #3: ensure the preparation observer is registered
            // BEFORE the first CoreML compile starts — otherwise the
            // engine fires the "preparing" callback into a nil
            // observer, `isPreparingModel` never flips to true, and the
            // Record button stays enabled while the encoder is still
            // cold. The Task in `init` serializes through the same
            // engine actor, but await ordering between two independent
            // Tasks is undefined, so we make it explicit here.
            await observerTask.value
            do {
                try await engine.loadIfNeeded(modelURL: modelURL, displayName: displayName)
                serviceLog.log("prewarm: completed for \(displayName, privacy: .public)")
            } catch {
                // Silent — the real transcription call will retry and
                // can surface any error through its own path.
                // The model name and the whisper error are app/model state,
                // not user content — no recording is involved in a prewarm.
                serviceLog.error("""
                    prewarm: failed for \(displayName, privacy: .public) \
                    (will retry on first use): \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
    }

    // MARK: - Public API

    /// IDs enqueued as a manual re-transcribe. Consumed by `process` to make
    /// the issue-#61 auto-drop gate an *explicit* first-transcription check
    /// rather than one inferred from an empty transcript — a recording that
    /// previously failed empty also has empty `fullText`, so inference alone
    /// could hard-delete it (plus its audio) on a deliberate retry.
    private var retranscriptionIDs: Set<UUID> = []

    /// Enqueue a recording for transcription. Returns immediately.
    /// Calls don't overlap — the queue drains FIFO on a single background task.
    /// Idempotent: re-enqueuing the active or already-queued recording is a no-op.
    /// `isRetranscription` marks a deliberate re-run of an existing recording so
    /// the auto-drop gate never discards it (see `retranscriptionIDs`).
    func enqueue(_ recording: Recording, isRetranscription: Bool = false) {
        if activeRecordingID == recording.id { return }
        if queue.contains(where: { $0.id == recording.id }) { return }
        if isRetranscription { retranscriptionIDs.insert(recording.id) }
        queue.append(recording)
        publishPending()
        startWorkerIfNeeded()
        serviceLog.log("""
            queue: enqueued \(recording.id.uuidString.prefix(8), privacy: .public) \
            (\(recording.title, privacy: .private)), \
            queue depth: \(self.queue.count, privacy: .public)
            """)
    }

    /// Wait until the worker has fully drained the queue and gone idle.
    /// Used by tests to assert post-conditions deterministically.
    ///
    /// The loop exits the instant the queue drains, so a healthy run
    /// returns in milliseconds; `timeout` only caps a stuck run. It was
    /// 30s, which under the heavy `build-and-test` runner's load was too
    /// short — the background transcribe Task could be starved past 30s,
    /// so `waitForIdle` returned WHILE STILL BUSY and the caller asserted
    /// on stale state (flaked
    /// `test_changing_recording_language_routes_to_other_model_on_reenqueue`
    /// et al.). 90s gives the scheduler ample slack without affecting the
    /// common case; genuine deadlocks are still bounded by the CI
    /// per-test execution-time allowance.
    func waitForIdle(timeout: TimeInterval = 90) async {
        let deadline = Date().addingTimeInterval(timeout)
        while (activeRecordingID != nil || !queue.isEmpty) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Number of recordings ahead of `recording` in the queue.
    /// `nil` if the recording is not pending.
    func queuePosition(of recording: Recording) -> Int? {
        queue.firstIndex(where: { $0.id == recording.id })
    }

    /// One-shot transcription of an array of mono Float32 samples (16kHz).
    /// Used by dictation. Bypasses the queue — the engine actor still
    /// serializes work internally so this just waits its turn.
    ///
    /// The model is chosen based on `language`: Hebrew goes to ivrit.ai,
    /// English (and anything else) goes to the OpenAI turbo. If the
    /// language-best model isn't installed yet (download still in flight),
    /// we fall back to whatever's selected so the user gets *some* transcript.
    ///
    /// `audioCtx` is forwarded to the engine — see
    /// `TranscribingEngine.transcribe` for semantics. Defaults to `0`
    /// (= whisper default 1500 ctx) because the dictation path is the
    /// historical caller of this method and dictation has NOT been
    /// validated against audio_ctx truncation. Callers that want the
    /// VAD-tuned formula must pass `nil` explicitly.
    func transcribeOnce(samples: [Float], language: String, audioCtx: Int32? = 0) async -> String {
        let segs = await transcribeOnceSegments(samples: samples, language: language, audioCtx: audioCtx)
        return segs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Same as `transcribeOnce`, but returns whisper's timed segments
    /// instead of a concatenated string. Used by `LiveTranscriber` so it
    /// can keep per-segment timing through the live loop (required for
    /// rendering one line per utterance and for matching speakers to
    /// segments by time).
    ///
    /// `audioCtx` is forwarded to the engine — see
    /// `TranscribingEngine.transcribe` for semantics. Callers MUST be
    /// explicit:
    ///   * `LiveTranscriber` (VAD-bounded short utterances) → `nil`.
    ///   * Dictation (full-press audio) → `0`.
    ///   * Batch worker → never goes through here (calls `engine.transcribe`
    ///     directly with `0`).
    /// There is no default — the wrong choice silently degrades transcription
    /// quality on one path or the other, so make every call site declare its
    /// intent.
    /// Proactively verify a remote transcription backend at recording start so
    /// a bad API key or unreachable endpoint surfaces IMMEDIATELY — as the
    /// global "Transcription error" alert — instead of silently emptying the
    /// live transcript for the whole recording and only erroring on the Stop
    /// batch pass. No-op for the on-device backend.
    ///
    /// Reuses `RemoteTranscriptionSettings.testConnection()` (a cheap
    /// `GET /models`), which also refreshes the Settings status pill, then
    /// mirrors a failure into `lastError`. Non-fatal: recording proceeds and
    /// audio is saved regardless — this only gets the user a fast, actionable
    /// error rather than a mystery blank pane.
    func probeRemoteBackendIfActive() async {
        guard remoteSettings.isActive else { return }
        guard remoteSettings.isConfigured else {
            lastError = "Remote transcription is selected but not configured. Open Settings → Models to set the endpoint and API key."
            return
        }
        await remoteSettings.testConnection()
        // Drop a superseded/cancelled probe: the caller cancels this task when
        // the recording stops or a newer recording starts, so a late, out-of-
        // order failure can't overwrite UI state for a recording the user has
        // already moved past.
        if Task.isCancelled { return }
        if case .failed(let message) = remoteSettings.testStatus {
            lastError = "Remote transcription server check failed: \(message) Your audio is still being recorded — fix the endpoint or API key in Settings → Models, then re-transcribe."
        }
    }

    func transcribeOnceSegments(samples: [Float], language: String, audioCtx: Int32?) async -> [TranscriptSegment] {
        // Nothing was captured: don't hand it to any backend. The remote one
        // uploads a header-only file and gets back `HTTP 500: Failed to decode
        // audio.`, which the user reads as "the transcription server is down"
        // — a diagnosis they can neither confirm nor act on, when the real
        // problem is on this machine. Say what actually happened instead.
        // The local backend fails the same way, just more quietly. (issue #147)
        if AudioSignal.isSilent(samples) {
            serviceLog.error("transcribeOnceSegments: REFUSING to transcribe \(samples.count, privacy: .public) samples with no signal — capture produced nothing")
            if lastError == nil {
                lastError = Self.noAudioCapturedMessage
            }
            return []
        }
        // Remote backend: route dictation/live utterances to the configured
        // endpoint too, so the user's "global backend" choice holds for every
        // path. Misconfiguration degrades to an empty result (same contract as
        // a missing local model) rather than throwing into the live loop.
        if remoteSettings.isActive {
            guard remoteSettings.isConfigured,
                  let config = remoteSettings.currentConfig(for: language) else {
                serviceLog.log("transcribeOnceSegments: SKIP — remote backend active but not configured")
                return []
            }
            await remoteEngine.configure(config)
            do {
                let segs = try await remoteEngine.transcribe(samples: samples,
                                                             language: language,
                                                             audioCtx: audioCtx,
                                                             progress: nil,
                                                             isCancelled: nil)
                return segs
            } catch {
                // Log at .error: a remote failure (401/transport/server) repeats
                // on every utterance for the whole recording and silently empties
                // the live pane. Error level so it's visible in `log show`
                // WITHOUT --debug and stands out from the debug firehose.
                // `logMessage(for:)`, not `localizedDescription`: this is the
                // same "someone else's bytes are already inside the string"
                // shape as `LLMRunnerError.nonZeroExit` and
                // `SpeakerDiarizer.Error.diarizationFailed`, just over HTTP.
                // `RemoteWhisperEngine.RemoteError.http` embeds up to 200
                // characters of the endpoint's raw response body, and the
                // comment above says this line repeats on every utterance —
                // so a 401 wrote a fragment of the user's API key into the log
                // once per utterance, all recording long. The status code and
                // a byte count survive; `lastError` below keeps the full text
                // for the banner. (Issue #213, CWE-532.)
                serviceLog.error("""
                    transcribeOnceSegments(remote): FAILED \
                    error=\(RemoteWhisperEngine.RemoteError.logMessage(for: error), privacy: .public)
                    """)
                // Surface the failure instead of returning a silently-empty
                // result that's indistinguishable from "no speech". Set once
                // (only when nothing is already showing) so a per-utterance
                // failure loop doesn't churn the alert every few seconds — the
                // record-start probe (`probeRemoteBackendIfActive`) is the
                // primary, up-front surfacing; this is the mid-recording backstop.
                if lastError == nil {
                    lastError = "Live transcription failed: \(error.localizedDescription)"
                }
                return []
            }
        }
        let candidate = modelManager.model(for: language)
        guard let model = candidate,
              modelManager.isInstalled(model) else {
            serviceLog.log("transcribeOnceSegments: SKIP — model not installed for lang=\(language, privacy: .public) candidate=\(candidate?.name ?? "nil", privacy: .public) installed=\(self.modelManager.installed, privacy: .public)")
            return []
        }
        let modelURL = modelManager.url(for: model)
        let startedAt = Date()
        serviceLog.log("transcribeOnceSegments: loading model=\(model.name, privacy: .public) at \(modelURL.path, privacy: .public)")
        // Bugbot #3: make sure the preparation observer is installed
        // before `loadIfNeeded` — see `init` for the race.
        await observerSetupTask.value
        do {
            try await engine.loadIfNeeded(modelURL: modelURL,
                                          displayName: model.displayName)
            let segs = try await engine.transcribe(samples: samples,
                                                   language: language,
                                                   audioCtx: audioCtx,
                                                   progress: nil,
                                                   isCancelled: nil)
            serviceLog.log("transcribeOnceSegments: model=\(model.name, privacy: .public) lang=\(language, privacy: .public) samples=\(samples.count, privacy: .public) elapsed=\(Date().timeIntervalSince(startedAt), privacy: .public)s segs=\(segs.count, privacy: .public)")
            return segs
        } catch {
            serviceLog.error("transcribeOnceSegments: FAILED model=\(model.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Re-run the OFFLINE speaker diarizer on an already-transcribed
    /// recording's WAV and return its segments with refreshed speaker
    /// labels — WITHOUT re-running whisper. Used by the live/authoritative
    /// stop path (meeting mode) to replace the online diarizer's
    /// over-segmented labels with the offline pipeline's global clustering,
    /// which produces far cleaner speaker counts.
    ///
    /// Returns nil (so the caller keeps the existing live speakers) when
    /// diarization isn't configured, there are no segments, the offline pass
    /// yields no turns, or it throws. The whole pass runs off-main inside
    /// `SpeakerDiarizer.diarize`.
    ///
    /// Pass `recordingID` so the UI can show an accurate "Identifying
    /// speakers…" status (via `diarizingRecordingID`) for exactly the
    /// recording being re-diarized — the transcript text is already final
    /// here, so calling this "Transcribing" would mislead.
    func rediarizeSegments(wavURL: URL, segments: [TranscriptSegment], recordingID: UUID? = nil) async -> [TranscriptSegment]? {
        guard diarizationSettings.isConfigured, !segments.isEmpty else { return nil }
        diarizingRecordingID = recordingID
        defer { diarizingRecordingID = nil }
        do {
            let turns = try await SpeakerDiarizer.diarize(wavURL: wavURL,
                                                          pythonPath: diarizationSettings.pythonPath)
            guard !turns.isEmpty else { return nil }
            var enriched = segments
            for i in enriched.indices {
                enriched[i].speaker = SpeakerDiarizer.assignSpeaker(
                    segmentStart: enriched[i].start,
                    segmentEnd: enriched[i].end,
                    turns: turns)
            }
            let normalized = Self.normalizeSpeakerLabels(in: enriched)
            let distinct = Set(normalized.compactMap(\.speaker)).count
            serviceLog.log("rediarizeSegments: offline pass labeled \(normalized.count, privacy: .public) segments with \(distinct, privacy: .public) speakers (was \(Set(segments.compactMap(\.speaker)).count, privacy: .public) live)")
            return normalized
        } catch {
            // Same subprocess-output leak as the batch diarization path:
            // `SpeakerDiarizer.Error.diarizationFailed` carries the Python
            // stderr, which prints the title-derived WAV path. (Issue #213.)
            serviceLog.log("""
                rediarizeSegments: failed (keeping live speakers): \
                \(SpeakerDiarizer.Error.logMessage(for: error), privacy: .public)
                """)
            return nil
        }
    }

    /// Free engine resources synchronously. Called from the AppDelegate at
    /// shutdown so the ggml-metal device tear-down happens before libc++
    /// global destructors run (which is what triggered SIGABRT on quit).
    func shutdown() async {
        await engine.shutdown()
        await remoteEngine.shutdown()
    }

    /// Abandon the transcription of `recordingID`. If it's still in the queue
    /// it's dropped; if it's the active job, the engine's abort_callback
    /// trips on the next poll and `whisper_full` unwinds in ~100ms instead
    /// of running to the end. Idempotent — repeated calls are a no-op.
    ///
    /// We do NOT delete the recording from the store here. The caller (the
    /// rename-sheet's Cancel button) is the one that decides whether to
    /// discard the audio or keep it — keeping that policy out of the service
    /// means the service stays composable for other potential cancel paths.
    func cancel(recordingID: UUID) {
        cancellation.insert(recordingID)
        queue.removeAll { $0.id == recordingID }
        publishPending()
    }

    // MARK: - Worker

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        while let next = popNext() {
            await process(next)
        }
        worker = nil
    }

    private func popNext() -> Recording? {
        guard !queue.isEmpty else { return nil }
        let next = queue.removeFirst()
        publishPending()
        return next
    }

    private func publishPending() {
        pendingIDs = queue.map(\.id)
    }

    private func process(_ recording: Recording) async {
        // The user may have hit Cancel between enqueue and now. Don't spin up
        // the model just to throw the result away.
        if cancellation.contains(recording.id) {
            serviceLog.log("""
                skipped \(recording.id.uuidString.prefix(8), privacy: .public) \
                (\(recording.title, privacy: .private)): cancelled before processing
                """)
            cancellation.remove(recording.id)
            return
        }

        // Re-fetch from the store BEFORE resolving backend/model/audio so every
        // downstream choice uses the same live recording snapshot. The enqueued
        // `recording` can be stale: a re-transcribe-in-other-language switches
        // the store's `language` (via `prepareForRetranscription`) after the
        // snapshot was captured, and the previous pass's compression may have
        // renamed the audio. Picking the model from the stale `recording.language`
        // while transcribing with `working.language` (below) could load/persist
        // the wrong model for the language actually transcribed.
        // (The recording may also have been edited or soft-deleted in the gap.)
        //
        // NOTE: this snapshot goes stale again the moment the pass starts — the
        // user keeps editing the row while we transcribe. From here on it is a
        // local scratch buffer for the pass's own output and is NEVER written
        // back to the store as-is; every write goes through `mergePassResult`,
        // which re-reads the live row and applies just the pass-owned fields.
        var working = store.recordings.first(where: { $0.id == recording.id }) ?? recording
        // Whether this is the recording's FIRST transcription — the only case
        // the issue-#61 auto-drop gate may discard a recording. A manual
        // re-transcribe must NEVER be dropped even if it comes back empty
        // (that would delete an existing recording + its audio). Use the
        // explicit `enqueue(isRetranscription:)` flag (consumed here), AND
        // require an empty prior `fullText`, so neither a UI retry of a
        // previously-failed-empty recording nor a recovered re-run is dropped.
        // Captured before `fullText` is overwritten below. See issue #61 review.
        let wasRetranscribeEnqueue = retranscriptionIDs.remove(recording.id) != nil
        let isFirstTranscription = !wasRetranscribeEnqueue
            && working.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if working.isTrashed {
            serviceLog.log("""
                skipped \(working.id.uuidString.prefix(8), privacy: .public) \
                (\(working.title, privacy: .private)): deleted before processing
                """)
            return
        }

        // Resolve the backend up front. Remote skips the local-model gate
        // entirely (a remote-only user may never have downloaded a `.bin`);
        // local keeps the existing "is the model installed yet?" guards.
        let useRemote = remoteSettings.isActive
        let localModel: WhisperModel?
        let modelDisplayName: String
        if useRemote {
            // Language-routed: a server whose primary model is Hebrew-only (the
            // ivrit.ai finetune) needs the English model id for English audio,
            // or the transcript comes back with Hebrew words spliced in.
            guard remoteSettings.isConfigured,
                  let config = remoteSettings.currentConfig(for: working.language) else {
                lastError = "Remote transcription is selected but not configured. Open Settings → Models to set the endpoint and API key."
                markFailed(recording)
                return
            }
            await remoteEngine.configure(config)
            localModel = nil
            // Label from the captured config, not remoteSettings — a Settings
            // edit mid-run must not change what's persisted to this
            // recording's modelName.
            modelDisplayName = "Remote · \(config.model)"
        } else {
            guard let model = modelManager.model(for: working.language) else {
                lastError = "No model selected."
                markFailed(recording)
                return
            }
            guard modelManager.isInstalled(model) else {
                lastError = "Whisper model is still downloading. Try again once it's ready."
                serviceLog.log("skipped: model \(model.name, privacy: .public) not installed yet")
                markFailed(recording)
                return
            }
            localModel = model
            modelDisplayName = model.displayName
        }
        let activeEngine: any TranscribingEngine = useRemote ? remoteEngine : engine

        // Snapshot pre-run summary state so the completion hook can tell
        // the summarizer "this was a re-transcription, force-regenerate."
        // We intentionally do NOT clear `summary` here — leaving the old
        // value visible during the re-run is less jarring than blanking
        // it for the ~30-60s the model takes; the post-completion
        // regenerate path replaces it atomically when the new transcript
        // is in hand. See PR body for the UX rationale.
        let hadSummaryBeforeRun = !(working.summary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty

        // Flip the LIVE row to `.running` rather than writing the whole snapshot
        // back — `await remoteEngine.configure` above is a suspension point the
        // user can rename/file/delete the row through. See `mergePassResult`.
        // (`working` is deliberately NOT re-seeded from the result: the pass must
        // keep transcribing the `language` it just resolved a model for.)
        working.status = .running
        working.modelName = modelDisplayName
        mergePassResult(id: recording.id) {
            $0.status = working.status
            $0.modelName = working.modelName
        }

        let recordingID = recording.id
        activeRecordingID = recordingID
        progress = 0

        defer {
            // Only clear UI state if it still belongs to *us*. Defensive — with
            // a serial queue there's no overlap, but we want to be safe in
            // case a future change reintroduces it.
            if activeRecordingID == recordingID {
                activeRecordingID = nil
                progress = 0
            }
        }

        serviceLog.log("""
            begin \(recordingID.uuidString.prefix(8), privacy: .public) \
            (\(working.title, privacy: .private))
            """)

        // Bugbot #3: make sure the preparation observer is installed
        // before `loadIfNeeded` — see `init` for the race.
        await observerSetupTask.value

        do {
            // Local backend needs the whisper weights loaded (and the CoreML
            // encoder compiled) before transcribing. The remote engine has no
            // weights — `configure` already ran above.
            if let localModel {
                try await engine.loadIfNeeded(modelURL: modelManager.url(for: localModel),
                                              displayName: localModel.displayName)
            }
            // Resolve the audio URL from the freshly re-fetched `working`
            // record, NOT the stale `recording` snapshot captured at enqueue
            // time. A re-transcribe (right-click "Re-transcribe in …") enqueues
            // a snapshot still pointing at the original `.wav`, but the previous
            // pass's background compression may have since renamed that file to
            // `.m4a` and deleted the `.wav`. Reading the stale `.wav` path would
            // then throw "file not found", failing the re-transcribe and leaving
            // the old transcript in place. `working` always reflects the current
            // on-disk name. (Paired with the compress/re-transcribe guard in
            // `RecordingStore.compressRecordingAudio`.)
            let audioURL = store.audioURL(for: working)
            let samples = try AudioConvert.loadAsWhisperSamples(url: audioURL)
            let durationSeconds = Double(samples.count) / Double(WhisperAudioFormat.sampleRate)
            let peak = samples.map { abs($0) }.max() ?? 0
            // The audio FILENAME is title-derived (`freshAudioURL`), so it is
            // `.private`; the sample count, duration and peak are the numbers
            // that make a silent-capture report diagnosable and stay public.
            serviceLog.log("""
                loaded \(samples.count, privacy: .public) samples \
                (\(String(format: "%.2f", durationSeconds), privacy: .public)s, \
                peak=\(String(format: "%.4f", peak), privacy: .public)) \
                for \(recordingID.uuidString.prefix(8), privacy: .public) \
                from \(audioURL.lastPathComponent, privacy: .private)
                """)

            // Reject essentially-silent / extremely-short audio BEFORE handing
            // it to Whisper. Otherwise the auto-gain step would amplify mic
            // noise to clipping levels and Whisper would hallucinate a
            // confident-looking transcript — that's the "every empty
            // recording got the same Hebrew test phrase" bug.
            if durationSeconds < Self.minimumAudioDurationSeconds || peak < Self.minimumAudioPeak {
                // Silently mark the recording failed instead of popping a
                // modal alert. Queue-driven transcription runs in the
                // background (post-record, crash recovery on launch,
                // re-transcribe button) — at none of those moments does
                // the user want a popup interrupting them. The .failed
                // status in the list is enough self-serve signal; the
                // detail view shows "No transcript yet" + a Transcribe
                // button if the user wants to retry on a noisier mic.
                serviceLog.log("""
                    rejecting \(recordingID.uuidString.prefix(8), privacy: .public) \
                    (\(working.title, privacy: .private)) — too short or too quiet \
                    to be real speech
                    """)
                working.status = .failed
                working.fullText = ""
                working.segments = []
                // Auto-drop accidental short+empty captures (issue #61) before
                // we persist the .failed row: a sub-threshold clip with no
                // transcribable audio is pure list spam. A long-but-silent clip
                // is over the threshold, so the gate keeps it as .failed.
                if autoDropIfShortAndEmpty(working, duration: durationSeconds, transcript: "", isFirstTranscription: isFirstTranscription) { return }
                // Merge onto the live row rather than writing the snapshot
                // back (see `mergePassResult`). This branch produced no
                // transcript, so the only fields the pass owns here are the
                // status and the (emptied) transcript output.
                mergePassResult(id: recording.id) {
                    $0.status = working.status
                    $0.fullText = working.fullText
                    $0.segments = working.segments
                }
                return
            }

            // Run diarization (Python subprocess) concurrently with whisper
            // transcription (in-process via ggml). They use independent
            // compute paths (Python/MPS vs whisper.cpp/Metal) and both read
            // from the same WAV file, so parallelism is safe and saves time.
            let shouldDiarize = diarizationSettings.isConfigured
            let diarPythonPath = diarizationSettings.pythonPath

            async let diarizeTask: [SpeakerTurn] = {
                guard shouldDiarize else { return [] }
                serviceLog.log("running speaker diarization…")
                do {
                    let turns = try await SpeakerDiarizer.diarize(
                        wavURL: audioURL,
                        pythonPath: diarPythonPath
                    )
                    let speakerCount = Set(turns.map(\.speaker)).count
                    serviceLog.log("""
                        diarization found \(speakerCount, privacy: .public) speakers \
                        across \(turns.count, privacy: .public) turns
                        """)
                    return turns
                } catch {
                    // `SpeakerDiarizer.Error.diarizationFailed` wraps the
                    // Python subprocess's stderr verbatim, and that stderr
                    // prints the WAV path it was handed — a title-derived
                    // filename. `logMessage(for:)` keeps the failure and drops
                    // the bytes. (Issue #213.)
                    serviceLog.error("""
                        diarization failed (continuing without speakers): \
                        \(SpeakerDiarizer.Error.logMessage(for: error), privacy: .public)
                        """)
                    return []
                }
            }()

            // Per-run coalescer: whisper fires its progress callback many
            // times/sec from a background compute thread. Funnelling each tick
            // through its own `Task { @MainActor }` flooded the main actor (one
            // @Published mutation + full re-render per tick) and applied values
            // out of order. The coalescer bounds outstanding work to a single
            // pending main-actor flush and keeps `progress` monotonic. Local to
            // this run so there's no cross-recording state to reset.
            let progressCoalescer = ProgressCoalescer()

            async let transcribeTask = activeEngine.transcribe(
                samples: samples,
                language: working.language,
                // Batch path: imported files / post-record full-WAV
                // transcription. We don't have a labelled fixture set
                // for this distribution (variable length, mic, noise
                // profile), so opt out of the live-VAD-tuned audio_ctx
                // truncation and use whisper's default 1500-token
                // context. This is a deliberate fix from PR #32 review:
                // applying the formula here regressed WER on the CI
                // e2e short-clip case (en_numbers_and_dates 5.17s,
                // 0.29 → 0.36 on ggml-tiny).
                audioCtx: 0,
                progress: { [weak self, progressCoalescer] p in
                    // Cheap, lock-guarded, no allocation on the hot path.
                    // Only schedule a main-actor flush when one isn't already
                    // pending — that's what caps the flood.
                    guard progressCoalescer.offer(Double(p)) else { return }
                    Task { @MainActor [weak self, progressCoalescer] in
                        let latest = progressCoalescer.flush()
                        guard let self, self.activeRecordingID == recordingID else { return }
                        self.progress = latest
                    }
                },
                // Polled by whisper.cpp's abort_callback between every
                // compute step. Reads against the lock-protected flag set so
                // the cross-thread access is sound.
                isCancelled: { [cancellation] in
                    cancellation.contains(recordingID)
                }
            )

            let (speakerTurns, segments) = try await (diarizeTask, transcribeTask)

            // Cover the narrow window where transcription completed BEFORE the
            // user hit Cancel (so the abort_callback never tripped) but the
            // coordinator is about to delete the recording. Don't write a
            // `.completed` row to a recording that's already gone.
            if cancellation.contains(recordingID) {
                serviceLog.log("""
                    cancelled post-run \(recordingID.uuidString.prefix(8), privacy: .public) \
                    (\(working.title, privacy: .private))
                    """)
                cancellation.remove(recordingID)
                return
            }

            var enrichedSegments = segments
            // A server-side diarizer (`gpt-4o-transcribe-diarize`, whose
            // `diarized_json` segments already carry speakers) has done this
            // job already, on the whole file, and its labels are the ones the
            // transcript's own turn boundaries were cut on. The local pyannote
            // pass ran concurrently with transcription, so we cannot know in
            // advance whether it will be needed — but overwriting labels the
            // transcript already has would re-cluster the same audio worse
            // and, because the offline pass has its own segment boundaries,
            // silently misalign the result. Server labels win. (issue #180)
            if Self.hasSpeakerLabels(segments) {
                let distinct = Set(segments.compactMap(\.speaker)).count
                serviceLog.log("""
                    keeping the \(distinct, privacy: .public) server-side speaker labels \
                    — not overwriting them with the offline pass
                    """)
            } else if !speakerTurns.isEmpty {
                for i in enrichedSegments.indices {
                    enrichedSegments[i].speaker = SpeakerDiarizer.assignSpeaker(
                        segmentStart: enrichedSegments[i].start,
                        segmentEnd: enrichedSegments[i].end,
                        turns: speakerTurns
                    )
                }
                // Normalize speaker labels to be sequential by first
                // appearance. Pyannote's clustering can yield gaps
                // (SPEAKER_00 then SPEAKER_02) when intermediate
                // clusters are merged away — which then shows up as
                // "Speaker A" + "Speaker C" with no B. Friendlier to
                // re-key everything as 00, 01, 02… in transcript order.
                enrichedSegments = Self.normalizeSpeakerLabels(in: enrichedSegments)
                let labeled = enrichedSegments.compactMap(\.speaker).count
                let distinct = Set(enrichedSegments.compactMap(\.speaker)).count
                serviceLog.log("""
                    applied speaker labels — \(labeled, privacy: .public)/\
                    \(enrichedSegments.count, privacy: .public) segments labeled, \
                    \(distinct, privacy: .public) distinct speakers
                    """)
            } else {
                serviceLog.log("""
                    NO speaker labels — shouldDiarize=\(shouldDiarize, privacy: .public), \
                    speakerTurns.count=0. Either diarization is not configured, returned \
                    no turns, or the pyannote subprocess failed (see the diarization \
                    failure line above).
                    """)
            }

            let text = enrichedSegments.map(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            serviceLog.log("""
                done \(recordingID.uuidString.prefix(8), privacy: .public) \
                (\(working.title, privacy: .private)) -> \
                \(enrichedSegments.count, privacy: .public) segments, \
                \(text.count, privacy: .public) chars
                """)

            working.segments = enrichedSegments
            // The batch pass minted fresh speaker IDs (new clustering, new
            // segment boundaries) with no alignment to the old ones, so any
            // user-assigned names are now keyed to meaningless IDs — clear
            // them rather than mislabel a different voice. Only explicit
            // re-transcribes of a renamed recording hit this in practice.
            working.speakerNames = [:]
            working.fullText = text
            if let lastEnd = enrichedSegments.last?.end, lastEnd > 0 {
                working.duration = lastEnd
            }
            working.status = text.isEmpty ? .failed : .completed
            // Auto-drop accidental short+empty captures (issue #61): a clip
            // that came back with NO transcript AND is under the user's
            // minimum-duration threshold is a hotkey misfire / silence — drop
            // it instead of leaving a .failed row cluttering the list. The gate
            // keeps any clip that produced text (even a short one) and anything
            // at/over the threshold, so this only ever removes worthless rows.
            if autoDropIfShortAndEmpty(working, duration: durationSeconds, transcript: text, isFirstTranscription: isFirstTranscription) { return }
            // Merge the pass output onto the LIVE row instead of writing the
            // snapshot captured minutes ago back over it — see
            // `mergePassResult` for the full field-ownership table. `nil` means
            // the row is gone (hard-deleted / trash emptied / just auto-dropped
            // above); there is nothing to write and nothing to follow up on.
            guard let persisted = mergePassResult(id: recording.id, {
                $0.status = working.status
                $0.segments = working.segments
                $0.fullText = working.fullText
                $0.duration = working.duration
                $0.modelName = working.modelName
                // Only a pass that actually produced segments owns this. Such a
                // pass re-keyed every SPEAKER_NN, so names bound to the old IDs
                // would now label a different voice — hence the reset above. A
                // pass that came back EMPTY minted no IDs and owns nothing here,
                // so the user's speaker names must survive it untouched (they're
                // hand-typed work, and the next successful pass re-keys anyway).
                if !enrichedSegments.isEmpty {
                    $0.speakerNames = working.speakerNames
                }
            }) else {
                serviceLog.log("""
                    \(recordingID.uuidString.prefix(8), privacy: .public) \
                    (\(working.title, privacy: .private)) vanished from the store \
                    mid-pass — result discarded, row not recreated
                    """)
                return
            }
            if persisted.status == .completed {
                if persisted.isTrashed {
                    // The user sent this to Recently Deleted mid-pass. It keeps
                    // its transcript (so a restore isn't empty) but gets none of
                    // the *user-facing* completion work: no stray `.srt` sidecar
                    // on disk, and no summarizer/LLM spend on something the user
                    // just threw away.
                    serviceLog.log("""
                        \(persisted.id.uuidString.prefix(8), privacy: .public) \
                        (\(persisted.title, privacy: .private)) was moved to Recently \
                        Deleted mid-pass — transcript saved, skipping SRT + summary
                        """)
                } else {
                    TranscriptExporter.writeSRT(for: persisted, in: store.recordingsDirectory)
                    onTranscriptionCompleted?(persisted, hadSummaryBeforeRun)
                }
                // Shrink storage: transcode the WAV to m4a now that
                // transcription + diarization are done reading it. Runs in
                // the background so it doesn't hold up the queue; playback
                // and re-transcribe read m4a natively, re-diarize decodes
                // it. No-op on already-compressed (imported) audio. Trashed
                // recordings get this too — their audio sits on disk until the
                // trash is emptied, and a restore shouldn't come back
                // uncompressed.
                let compressID = persisted.id
                Task { await store.compressRecordingAudio(id: compressID) }
            }
        } catch is CancellationError {
            // The user hit Cancel mid-run. The rename sheet's coordinator is
            // also going to hard-delete the recording from the store — don't
            // race with that by writing a `.failed` status, and don't surface
            // a scary error banner for what was a user-initiated action.
            serviceLog.log("""
                cancelled mid-run \(recordingID.uuidString.prefix(8), privacy: .public) \
                (\(working.title, privacy: .private))
                """)
            cancellation.remove(recording.id)
        } catch {
            // The pass reads the recording's own audio and writes its
            // transcript, both under the (possibly user-chosen) recordings
            // directory with title-derived names — so a Cocoa error here
            // quotes a title, or the folder holding it. Domain + code stay
            // public: they separate "file missing" from "no permission" from
            // a decode failure, and name nothing.
            let ns = error as NSError
            serviceLog.error("""
                error for \(recordingID.uuidString.prefix(8), privacy: .public) \
                (\(working.title, privacy: .private)) \
                [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)]: \
                \(error.localizedDescription, privacy: .private)
                """)
            // A failed pass produced no transcript, so `status` is the ONLY
            // field it owns here — in particular it must not overwrite
            // `speakerNames`/`segments`, which it never re-keyed. Merging onto
            // the live row also means a rename/re-file/soft-delete the user
            // made while the pass was failing survives (see `mergePassResult`).
            mergePassResult(id: recording.id) { $0.status = .failed }
            lastError = "Transcription failed: \(error.localizedDescription)"
        }
    }

    /// Whether `segments` already carry speaker labels — i.e. whoever produced
    /// them diarized them too. True for a `diarized_json` response from a
    /// remote diarization model; false for every local whisper.cpp result and
    /// for `verbose_json`/`json`, which have no speaker field at all.
    static func hasSpeakerLabels(_ segments: [TranscriptSegment]) -> Bool {
        segments.contains { $0.speaker?.isEmpty == false }
    }

    /// Re-key speaker labels in transcript order so the SET of labels
    /// is contiguous `SPEAKER_00`, `SPEAKER_01`, … with no gaps. The
    /// diarizer can return `{SPEAKER_00, SPEAKER_02}` when an
    /// intermediate cluster got merged by the clustering pipeline —
    /// without this the UI would show "Speaker A, Speaker C" with no
    /// B in between, which is confusing.
    ///
    /// First-appearance order is preferred over alphabetical so the
    /// person who spoke first is always `SPEAKER_00`.
    static func normalizeSpeakerLabels(in segments: [TranscriptSegment]) -> [TranscriptSegment] {
        // Implementation lives in `SpeakerLabels` so the remote engine — which
        // has to re-key a server-side diarizer's labels and is not on the main
        // actor — can share it instead of duplicating it.
        SpeakerLabels.normalized(in: segments)
    }

    private func markFailed(_ recording: Recording) {
        mergePassResult(id: recording.id) { $0.status = .failed }
    }

    /// Persist the result of a transcription pass by merging it onto the row
    /// that is in the store **right now**, instead of writing back the snapshot
    /// captured when the pass started.
    ///
    /// **Why.** A batch pass runs for as long as the audio takes — minutes on a
    /// long meeting — and every non-live recording goes through it
    /// (`QuickActionsController.finalizeTail` enqueues them). Throughout that
    /// window the user can rename the recording, drop it into a folder, rename
    /// speakers, or send it to Recently Deleted from the sidebar. The old
    /// `store.update(working)` wrote the stale snapshot over the live row and
    /// silently reverted all of it (issue #152). This is the same discipline the live
    /// finalize tail already applies ("we update only the segments rather than
    /// clobbering the row", `QuickActionsController`).
    ///
    /// **Field ownership.** `apply` receives the LIVE row and must set ONLY
    /// pass-owned fields. Anything a future change adds to `Recording` needs to
    /// be classified into one of these buckets:
    ///
    /// * **Pass-owned** — the transcription output and the metadata describing
    ///   the run that produced it: `status`, `segments`, `fullText`,
    ///   `duration`, `modelName`, and `speakerNames`. `speakerNames` is
    ///   pass-owned *only for a pass that produced segments*, because such a
    ///   pass re-keys every `SPEAKER_NN` and names assigned against the old IDs
    ///   would then label the wrong voice. A failed/rejected pass must leave it
    ///   alone.
    /// * **User-owned** — never written here; the live row always wins:
    ///   `title`, `folder`, `deletedAt`, `summary`, `actionItems`.
    /// * **Store-owned** — identity and provenance, also never written here:
    ///   `id`, `createdAt`, `source`, `audioFileName`, `appName`,
    ///   `voiceMemoUniqueID`, `voiceMemoFolderUUID`. (`audioFileName` in
    ///   particular: the post-completion compression renames the file, and
    ///   restoring the snapshot's name would point the row at a deleted `.wav`.)
    /// * `language` is deliberately **not** pass-owned. The pass only *reads*
    ///   it; `RecordingStore.prepareForRetranscription` is the writer, so an
    ///   in-flight language switch must not be rolled back by an older pass.
    ///
    /// **Deleted rows.** Returns `nil` — writing nothing — when the recording
    /// is gone from the store entirely: hard-deleted from the sidebar, or
    /// swept by Empty Trash. We never re-`add` it; resurrecting a row the user
    /// deleted is the failure mode this whole helper exists to prevent. (The
    /// `autoDropIfShortAndEmpty` gate that runs immediately before the
    /// completion write also removes the row, so the merge can never fight it
    /// — but its callers early-return on `true`, so that case never reaches
    /// here. The `nil` branch is the backstop if that ever changes.)
    /// A **soft**-deleted row is still written: its
    /// `deletedAt` is user-owned, so it stays in Recently Deleted, but the
    /// merge moves it out of `.running` into a terminal status (otherwise it
    /// would sit in the queue UI as "Transcribing" forever) and keeps the
    /// transcript around in case the user restores it.
    @discardableResult
    private func mergePassResult(id: UUID, _ apply: (inout Recording) -> Void) -> Recording? {
        guard var live = store.recordings.first(where: { $0.id == id }) else { return nil }
        apply(&live)
        store.update(live)
        return live
    }

    /// Permanently delete `recording` when the auto-drop gate flags it as an
    /// accidental short+empty capture (issue #61). Returns `true` if it
    /// dropped it (the caller should then early-return without persisting a
    /// `.failed`/`.completed` row). We hard-delete rather than soft-delete:
    /// these clips have no transcript and no audio worth keeping, so routing
    /// them through Recently Deleted would just leave orphaned audio on disk
    /// for the grace period. No-op when the gate isn't wired (tests) or the
    /// recording has real content / is long enough to keep.
    private func autoDropIfShortAndEmpty(_ recording: Recording, duration: Double, transcript: String, isFirstTranscription: Bool) -> Bool {
        // Only auto-drop a recording's FIRST transcription. A manual
        // re-transcribe of an existing recording that comes back empty must
        // NOT be deleted — that would destroy content the user already had.
        guard isFirstTranscription else { return false }
        // Only auto-drop accidental *local mic captures* (mic recordings +
        // dictation hotkey misfires — both `.microphone`). Never Voice Memos,
        // imported files (`.systemAudio`), or meeting captures: those aren't
        // accidental and/or their source audio wasn't captured in Mila, so
        // permanently deleting them would be data loss (issue #61 review).
        guard recording.source == .microphone else { return false }
        // Use the freshly-decoded audio duration, NOT `recording.duration`,
        // which can be stale (crash-recovered rows are seeded with 0) and
        // would let a long-but-silent clip slip under the threshold.
        guard shouldAutoDropShortEmpty?(duration, transcript) == true else { return false }
        serviceLog.log("""
            auto-dropping \(recording.id.uuidString.prefix(8), privacy: .public) \
            (\(recording.title, privacy: .private)) — \
            \(String(format: "%.2f", duration), privacy: .public)s + empty transcript \
            (issue #61)
            """)
        store.permanentlyDelete(recording)
        return true
    }
}

/// Coalesces high-frequency progress callbacks (fired from whisper.cpp's
/// background compute thread) into at most one pending main-actor update, and
/// keeps the reported value monotonic.
///
/// The previous code spawned a fresh `Task { @MainActor }` per whisper tick — an
/// unbounded flood of main-actor hops, each mutating `@Published progress` and
/// re-rendering every observing view. Worse, independent `Task`s have no
/// ordering guarantee, so a late-running earlier value could clobber a later
/// one, freezing the bar short of 100%. This bounds outstanding work to one
/// flush and applies `max`, so progress only ever moves forward.
///
/// `offer` runs on the compute thread and returns `true` when the caller should
/// schedule a main-actor flush (none pending). `flush` runs on the main actor,
/// returns the latest value, and clears the pending flag.
final class ProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Double = 0
    private var scheduled = false

    func offer(_ value: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        latest = max(latest, value)
        if scheduled { return false }
        scheduled = true
        return true
    }

    func flush() -> Double {
        lock.lock(); defer { lock.unlock() }
        scheduled = false
        return latest
    }
}

/// Thread-safe Set<UUID> for cancelled recording IDs.
///
/// Writes happen on `@MainActor` (`TranscriptionService.cancel(_:)`); reads
/// happen synchronously on whisper.cpp's compute thread (the `abort_callback`
/// it polls every step). The lock is the simplest shape that lets both sides
/// share state without strict-concurrency violations.
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<UUID> = []

    func insert(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        ids.insert(id)
    }

    func remove(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        ids.remove(id)
    }

    func contains(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ids.contains(id)
    }
}
