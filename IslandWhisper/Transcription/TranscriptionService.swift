import Foundation
import Combine

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
    @Published private(set) var progress: Double = 0
    @Published var lastError: String?

    /// Audio shorter than this is treated as "no recording" — Whisper happily
    /// hallucinates confident transcripts from sub-100ms noise.
    static let minimumAudioDurationSeconds: Double = 0.3
    /// Audio whose peak sample is below this is treated as silence. The
    /// auto-gain in WhisperEngine.normalize() would otherwise amplify it
    /// to clipping levels and produce ghost transcripts.
    static let minimumAudioPeak: Float = 0.005

    private let engine: any TranscribingEngine
    private let store: RecordingStore
    private let modelManager: ModelManager
    private let diarizationSettings: DiarizationSettings

    private var queue: [Recording] = []
    private var worker: Task<Void, Never>?

    init(store: RecordingStore,
         modelManager: ModelManager,
         diarizationSettings: DiarizationSettings,
         engine: any TranscribingEngine = WhisperEngine()) {
        self.store = store
        self.modelManager = modelManager
        self.diarizationSettings = diarizationSettings
        self.engine = engine
    }

    // MARK: - Public API

    /// Enqueue a recording for transcription. Returns immediately.
    /// Calls don't overlap — the queue drains FIFO on a single background task.
    /// Idempotent: re-enqueuing the active or already-queued recording is a no-op.
    func enqueue(_ recording: Recording) {
        if activeRecordingID == recording.id { return }
        if queue.contains(where: { $0.id == recording.id }) { return }
        queue.append(recording)
        publishPending()
        startWorkerIfNeeded()
        print("Transcribe queue: enqueued \(recording.title) [\(recording.id.uuidString.prefix(8))], queue depth: \(queue.count)")
    }

    /// Wait until the worker has fully drained the queue and gone idle.
    /// Used by tests to assert post-conditions deterministically.
    func waitForIdle(timeout: TimeInterval = 30) async {
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
    func transcribeOnce(samples: [Float], language: String) async -> String {
        guard let model = modelManager.model(for: language),
              modelManager.isInstalled(model) else {
            return ""
        }
        do {
            try await engine.loadIfNeeded(modelURL: modelManager.url(for: model),
                                          displayName: model.displayName)
            let segs = try await engine.transcribe(samples: samples,
                                                   language: language,
                                                   progress: nil)
            return segs.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            print("Dictation transcription error: \(error)")
            return ""
        }
    }

    /// Free engine resources synchronously. Called from the AppDelegate at
    /// shutdown so the ggml-metal device tear-down happens before libc++
    /// global destructors run (which is what triggered SIGABRT on quit).
    func shutdown() async {
        await engine.shutdown()
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
        guard let model = modelManager.model(for: recording.language) else {
            lastError = "No model selected."
            markFailed(recording)
            return
        }
        guard modelManager.isInstalled(model) else {
            lastError = "Whisper model is still downloading. Try again once it's ready."
            print("Transcribe skipped: model \(model.name) not installed yet")
            markFailed(recording)
            return
        }

        // Re-fetch from the store so we work against the latest persisted version.
        // (The recording may have been edited or even soft-deleted between
        //  enqueue() and now.)
        var working = store.recordings.first(where: { $0.id == recording.id }) ?? recording
        if working.isTrashed {
            print("Transcribe skipped: \(working.title) was deleted before processing")
            return
        }

        working.status = .running
        working.modelName = model.displayName
        store.update(working)

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

        print("Transcribe begin: \(working.title) [\(recordingID.uuidString.prefix(8))]")

        do {
            try await engine.loadIfNeeded(modelURL: modelManager.url(for: model),
                                          displayName: model.displayName)
            let audioURL = store.audioURL(for: recording)
            let samples = try AudioConvert.loadAsWhisperSamples(url: audioURL)
            let durationSeconds = Double(samples.count) / Double(WhisperAudioFormat.sampleRate)
            let peak = samples.map { abs($0) }.max() ?? 0
            print(String(format: "Transcribe: loaded %d samples (%.2fs, peak=%.4f) from %@",
                         samples.count, durationSeconds, peak, audioURL.lastPathComponent))

            // Reject essentially-silent / extremely-short audio BEFORE handing
            // it to Whisper. Otherwise the auto-gain step would amplify mic
            // noise to clipping levels and Whisper would hallucinate a
            // confident-looking transcript — that's the "every empty
            // recording got the same Hebrew test phrase" bug.
            if durationSeconds < Self.minimumAudioDurationSeconds || peak < Self.minimumAudioPeak {
                print("Transcribe: rejecting \(working.title) — too short or too quiet to be real speech")
                working.status = .failed
                working.fullText = ""
                working.segments = []
                store.update(working)
                lastError = "Recording is too quiet or too short to transcribe. Check your microphone."
                return
            }

            // Run diarization (Python subprocess) concurrently with whisper
            // transcription (in-process via ggml). They use independent
            // compute paths (Python/MPS vs whisper.cpp/Metal) and both read
            // from the same WAV file, so parallelism is safe and saves time.
            let shouldDiarize = diarizationSettings.isConfigured
            let diarHfToken = diarizationSettings.hfToken
            let diarPythonPath = diarizationSettings.pythonPath

            async let diarizeTask: [SpeakerTurn] = {
                guard shouldDiarize else { return [] }
                print("Transcribe: running speaker diarization...")
                do {
                    let turns = try await SpeakerDiarizer.diarize(
                        wavURL: audioURL,
                        hfToken: diarHfToken,
                        pythonPath: diarPythonPath
                    )
                    let speakerCount = Set(turns.map(\.speaker)).count
                    print("Transcribe: diarization found \(speakerCount) speakers across \(turns.count) turns")
                    return turns
                } catch {
                    print("Transcribe: diarization failed (continuing without speakers): \(error)")
                    return []
                }
            }()

            async let transcribeTask = engine.transcribe(
                samples: samples,
                language: working.language,
                progress: { [weak self] p in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.activeRecordingID == recordingID else { return }
                        self.progress = Double(p)
                    }
                }
            )

            let (speakerTurns, segments) = try await (diarizeTask, transcribeTask)

            var enrichedSegments = segments
            if !speakerTurns.isEmpty {
                for i in enrichedSegments.indices {
                    enrichedSegments[i].speaker = SpeakerDiarizer.assignSpeaker(
                        segmentStart: enrichedSegments[i].start,
                        segmentEnd: enrichedSegments[i].end,
                        turns: speakerTurns
                    )
                }
            }

            let text = enrichedSegments.map(\.text)
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("Transcribe done: \(working.title) -> \(enrichedSegments.count) segments, \(text.count) chars")

            working.segments = enrichedSegments
            working.fullText = text
            if let lastEnd = enrichedSegments.last?.end, lastEnd > 0 {
                working.duration = lastEnd
            }
            working.status = text.isEmpty ? .failed : .completed
            store.update(working)

            if working.status == .completed {
                TranscriptExporter.writeSRT(for: working, in: store.recordingsDirectory)
            }
        } catch {
            print("Transcribe error for \(working.title): \(error)")
            working.status = .failed
            store.update(working)
            lastError = "Transcription failed: \(error.localizedDescription)"
        }
    }

    private func markFailed(_ recording: Recording) {
        if var working = store.recordings.first(where: { $0.id == recording.id }) {
            working.status = .failed
            store.update(working)
        }
    }
}
