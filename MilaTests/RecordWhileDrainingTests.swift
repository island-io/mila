import XCTest
import TranscriptionCore
import MilaKit
@testable import Mila

/// Issue #356: "What is there to finalize when a conversation is done if it
/// was live transcribed and summarized, and why does it block me from
/// transcribing another conversation?"
///
/// After Stop, `stopRecording` drains the live pipeline — one last whisper
/// pass over the audio the live transcriber had not reached yet, the diarizer
/// queue, the snapshot onto the saved row, the live sidecar handoff — before
/// it lets go of the live singletons. The Record button used to be disabled
/// ("Finalizing…") for that whole drain, because a new recording's start
/// resets those same singletons under the snapshot.
///
/// Now only the stop itself (`isStoppingRecording`: closing the WAV and
/// saving the row) refuses a start. A start during the drain captures at
/// once; the reset of the live singletons and the Live AI session start it
/// would have made are DEFERRED until the drain clears
/// `isFinalizingRecording` (`releaseLivePipeline()`), and `MilaApp`'s live
/// wiring holds the new recording's audio until then and replays it.
///
/// These tests pin both halves: the new recording really starts during the
/// drain, and the drain still saves the PREVIOUS recording's transcript — the
/// thing the old gate existed to protect.
@MainActor
final class RecordWhileDrainingTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var session: RecordingSession!
    private var languageSettings: RecordingLanguageSettings!
    private var controller: QuickActionsController!
    private var transcriber: LiveTranscriber!

    private let suitePrefix = "RecordWhileDrainingTests"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: suitePrefix)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        store = RecordingStore(rootDirectory: tempRoot)
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        manager = TestSupport.isolatedModelManager(
            modelsDirectory: tempRoot.appendingPathComponent("Models"),
            label: suitePrefix)
        try TestSupport.installFakeModel(into: manager)

        stub = StubWhisperEngine()
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(
                defaults: .init(suiteName: "\(suitePrefix).diarization")!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: suitePrefix),
            engine: stub)
        session = RecordingSession()
        languageSettings = RecordingLanguageSettings(
            defaults: UserDefaults(suiteName: "\(suitePrefix).language")!)
        controller = QuickActionsController(
            session: session,
            store: store,
            transcription: service,
            languageSettings: languageSettings,
            postRecording: PostRecordingCoordinator(
                store: store,
                transcription: service,
                llm: LLMSettings(defaults: UserDefaults(suiteName: "\(suitePrefix).llm")!)))
        // The live transcriber `MilaApp` hands the controller. Fixed-window
        // mode (no VAD), so `transcribeNow()` is one whisper pass over the
        // buffered audio — a drain whose length the stub's delay controls.
        transcriber = LiveTranscriber(transcription: service)
        controller.liveTranscriber = transcriber
    }

    override func tearDown() async throws {
        transcriber?.stop()
        if session?.state != .idle { _ = await session?.stop() }
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        for suffix in ["diarization", "language", "llm"] {
            UserDefaults().removePersistentDomain(forName: "\(suitePrefix).\(suffix)")
        }
        try await super.tearDown()
    }

    private func freshWAV(_ name: String) throws -> URL {
        let url = store.freshAudioURL(suggestedName: name)
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.6)
        return url
    }

    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func row(for url: URL) -> Recording? {
        store.recordings.first { $0.audioFileName == url.lastPathComponent }
    }

    // MARK: -

    /// The scenario from the issue, end to end through the real
    /// `stopRecording`: Stop a live-transcribed recording, and start the next
    /// one while the first is still draining.
    ///
    /// Non-vacuous on both sides. Under the old gate the second start is
    /// refused (`activeJob` stays `.none`). And if the start were let through
    /// WITHOUT the deferral, `prepareLivePipeline()` would `reset()` the
    /// transcriber mid-drain: the drain's in-flight whisper pass would be
    /// dropped by the epoch guard and its snapshot would read an empty
    /// transcript, so the first recording would be saved without its text.
    func test_a_recording_can_start_while_the_previous_one_drains_and_both_keep_their_own_transcript() async throws {
        // Recording 1, with live audio the transcriber has not reached yet —
        // the tail the drain exists to transcribe.
        let url1 = try freshWAV("Draining")
        await controller.startFakeRecordingForTesting(outputURL: url1)
        transcriber.start(language: "en")
        // The drain's live pass returns the first meeting; anything after it
        // (the batch passes `finalizeTail` enqueues) returns other text, so
        // the first row's transcript can only have come from the drain.
        await stub.setCannedQueue([[TranscriptSegment(start: 0, end: 1.5, text: "first meeting tail")]])
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 0.5, text: "batch pass")])
        await stub.setDefaultDelay(1.0)
        transcriber.ingest(ArraySlice(Array(repeating: Float(0.3), count: 32_000)))

        // Stop 1. The drain's whisper pass takes ~1 s.
        let stop1 = Task { await controller.stopRecording() }
        let draining = await waitUntil {
            controller.activeJob == .none && controller.isFinalizingRecording
        }
        XCTAssertTrue(draining, "precondition: stop 1 should be in its live drain")
        XCTAssertFalse(controller.isStoppingRecording,
                       "the WAV is closed and the row saved — nothing a new recording has to wait for")

        // Recording 2, started mid-drain.
        let url2 = try freshWAV("StartedMidDrain")
        await controller.startFakeRecordingForTesting(outputURL: url2)
        XCTAssertEqual(controller.activeJob, .recording(withSystemAudio: false),
                       "a new recording must start while the previous one is still draining (#356)")
        XCTAssertEqual(session.state, .recording, "capture must be up immediately, not after the drain")
        XCTAssertTrue(controller.isFinalizingRecording,
                      "precondition: the start really landed inside the drain")
        XCTAssertTrue(controller.isAwaitingLivePipeline,
                      "the new recording must not have the live singletons while the drain still reads them")

        // Let the drain finish.
        await stop1.value
        XCTAssertFalse(controller.isFinalizingRecording)
        XCTAssertFalse(controller.isAwaitingLivePipeline,
                       "the drain's release hands the live pipeline to the new recording")
        XCTAssertTrue(transcriber.segments.isEmpty,
                      "the live transcriber is cleared for the new recording only once the drain is done with it")

        let first = try XCTUnwrap(row(for: url1))
        XCTAssertTrue(first.fullText.contains("first meeting tail"),
                      "the drain must still save the first recording's own live transcript, including the tail it transcribed after the second recording started — got \(first.fullText.debugDescription)")

        // Stop 2: its row must not inherit the first meeting's transcript.
        // Checked before any suspension, i.e. before the batch pass its
        // finalize tail enqueues can run.
        await controller.stopRecording()
        let second = try XCTUnwrap(row(for: url2))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertFalse(second.fullText.contains("first meeting"),
                       "the second recording must not be saved with the first one's live transcript")
        XCTAssertTrue(second.segments.isEmpty)

        await stub.setDefaultDelay(0)
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
        XCTAssertEqual(store.recordings.count, 2)
    }

    /// Stopping a recording that started during the previous drain, before
    /// that drain has released the live pipeline to it, must wait for the
    /// release. Proceeding would snapshot the transcriber — which still holds
    /// the PREVIOUS meeting — as this recording's transcript.
    func test_stopping_a_recording_still_waiting_for_the_live_pipeline_waits_for_the_release() async throws {
        // Stand-in for a previous recording's drain still owning the live
        // singletons, with its transcript still in the transcriber.
        transcriber.seedForTesting([
            LiveSegment(id: UUID(), startSeconds: 0, endSeconds: 1,
                        text: "previous meeting", speaker: nil, stable: true)
        ])
        controller.isFinalizingRecording = true

        let url = try freshWAV("StopBeforeHandover")
        await controller.startFakeRecordingForTesting(outputURL: url)
        XCTAssertTrue(controller.isAwaitingLivePipeline)
        XCTAssertEqual(transcriber.segments.map(\.text), ["previous meeting"],
                       "the start must not clear the transcriber the drain is still reading")

        let stop = Task { await controller.stopRecording() }
        let accepted = await waitUntil { controller.isStoppingRecording }
        XCTAssertTrue(accepted)
        // Give the stop every chance to run ahead if it were going to.
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(store.recordings.isEmpty,
                      "the stop must not save anything until the drain has released the live pipeline")
        XCTAssertEqual(session.state, .recording, "capture keeps running while the stop waits")

        // A second Stop while the first is pending is dropped, not queued.
        await controller.stopRecording()
        XCTAssertTrue(store.recordings.isEmpty)

        // The drain ends: the singletons are cleared and handed over, and the
        // stop proceeds.
        controller.isFinalizingRecording = false
        XCTAssertTrue(transcriber.segments.isEmpty)
        await stop.value

        XCTAssertEqual(store.recordings.count, 1, "exactly one row for one capture")
        let saved = try XCTUnwrap(row(for: url))
        XCTAssertFalse(saved.fullText.contains("previous meeting"),
                       "the recording must not be saved with the previous meeting's transcript")
        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertFalse(controller.isStoppingRecording)

        await controller.awaitFinalizeTails()
        await service.waitForIdle()
    }

    /// The ordinary path is untouched: with no drain in flight, a start
    /// clears the live transcriber straight away and is never left waiting.
    func test_a_start_with_no_drain_in_flight_takes_the_live_pipeline_at_once() async throws {
        transcriber.seedForTesting([
            LiveSegment(id: UUID(), startSeconds: 0, endSeconds: 1,
                        text: "stale", speaker: nil, stable: true)
        ])
        XCTAssertFalse(controller.isFinalizingRecording)

        let url = try freshWAV("NoDrain")
        await controller.startFakeRecordingForTesting(outputURL: url)
        XCTAssertFalse(controller.isAwaitingLivePipeline)
        XCTAssertTrue(transcriber.segments.isEmpty,
                      "with nothing draining, the previous recording's live state is cleared at record start as before")

        // Nothing parks here either.
        await controller.awaitLivePipelineAvailable()
    }
}
