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
/// These tests pin: the new recording really starts during the drain; the
/// drain still saves the PREVIOUS recording's transcript (the thing the old
/// gate existed to protect); the new recording can be stopped, and paused,
/// without waiting for that drain; and a dropped Stop does not leave a sleep
/// reason behind for the next recording.
@MainActor
final class RecordWhileDrainingTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var session: RecordingSession!
    private var languageSettings: RecordingLanguageSettings!
    private var postRecording: PostRecordingCoordinator!
    private var controller: QuickActionsController!
    private var transcriber: LiveTranscriber!
    private var sidecarRoot: URL!
    private var sidecar: LiveTranscriptSidecarWriter!

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
        postRecording = PostRecordingCoordinator(
            store: store,
            transcription: service,
            llm: LLMSettings(defaults: UserDefaults(suiteName: "\(suitePrefix).llm")!))
        controller = QuickActionsController(
            session: session,
            store: store,
            transcription: service,
            languageSettings: languageSettings,
            postRecording: postRecording)
        // The live sidecar is single-recording; only the drain that owns it
        // may close it. A long heartbeat keeps the timer out of the
        // assertions.
        sidecarRoot = tempRoot.appendingPathComponent("SidecarRoot", isDirectory: true)
        try FileManager.default.createDirectory(at: sidecarRoot, withIntermediateDirectories: true)
        sidecar = LiveTranscriptSidecarWriter(root: sidecarRoot,
                                              minWriteInterval: 0,
                                              heartbeatInterval: 3600)
        controller.liveSidecarWriter = sidecar
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

    /// Stand-in for a previous recording whose drain still owns the live
    /// singletons: its transcript is in the transcriber and its sidecar is
    /// open.
    private func simulatePreviousRecordingDraining() {
        transcriber.seedForTesting([
            LiveSegment(id: UUID(), startSeconds: 0, endSeconds: 1,
                        text: "previous meeting", speaker: nil, stable: true)
        ])
        sidecar.begin(title: "Previous", source: "microphone", liveAvailable: true)
        controller.isFinalizingRecording = true
    }

    /// Stopping a recording that started during the previous drain, before
    /// that drain has handed it the live pipeline, must NOT wait for the
    /// drain: a slow or hung drain would otherwise keep the mic open on a
    /// recording the user (or sleep / lock) stopped. It closes the capture at
    /// once and is saved for the batch pass — and it must not touch what the
    /// other drain is using: the transcriber's text, the
    /// `isFinalizingRecording` ownership, or the sidecar.
    func test_stopping_a_recording_still_waiting_for_the_live_pipeline_does_not_wait_for_the_other_drain() async throws {
        simulatePreviousRecordingDraining()

        let url = try freshWAV("StopBeforeHandover")
        await controller.startFakeRecordingForTesting(outputURL: url)
        XCTAssertTrue(controller.isAwaitingLivePipeline)
        XCTAssertEqual(transcriber.segments.map(\.text), ["previous meeting"],
                       "the start must not clear the transcriber the drain is still reading")

        // Called directly: if it waited for the other drain this would hang,
        // because nothing clears the flag before it returns.
        await controller.stopRecording()

        XCTAssertEqual(session.state, .idle, "the capture must be closed immediately")
        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertFalse(controller.isStoppingRecording)
        XCTAssertFalse(controller.isAwaitingLivePipeline)
        XCTAssertEqual(store.recordings.count, 1, "exactly one row for one capture")
        let saved = try XCTUnwrap(row(for: url))
        XCTAssertTrue(saved.fullText.isEmpty,
                      "it never had the live pipeline, so it has no live transcript — certainly not the previous meeting's")
        XCTAssertTrue(saved.segments.isEmpty)
        XCTAssertEqual(saved.status, .pending, "it goes to the batch pass, which has the whole WAV")

        // The other drain's state is untouched.
        XCTAssertTrue(controller.isFinalizingRecording,
                      "a stop that never owned the live pipeline must not end another drain's ownership")
        XCTAssertEqual(transcriber.segments.map(\.text), ["previous meeting"],
                       "nor tear down the transcriber that drain is reading")
        XCTAssertEqual(LiveTranscriptSnapshot.read(root: sidecarRoot)?.state, .recording,
                       "nor close the sidecar — its handoff belongs to that drain, after its store.update")

        // The drain ends: the deferred clear still happens, for whatever
        // records next.
        controller.isFinalizingRecording = false
        XCTAssertTrue(transcriber.segments.isEmpty)
        XCTAssertFalse(controller.isAwaitingLivePipeline)

        await controller.awaitFinalizeTails()
        await service.waitForIdle()
    }

    /// Pause used to be gated on `isFinalizingRecording`, which since #356
    /// can be the PREVIOUS recording's drain — so a recording started right
    /// after a Stop could not be paused until that drain finished. It is
    /// gated on this recording's own stop now.
    func test_a_recording_started_during_the_previous_drain_can_be_paused() async throws {
        simulatePreviousRecordingDraining()

        let url = try freshWAV("PauseDuringDrain")
        await controller.startFakeRecordingForTesting(outputURL: url)
        XCTAssertTrue(controller.isRecording)

        await controller.pauseRecording()
        XCTAssertTrue(controller.isPaused,
                      "the previous recording's drain must not block pausing this one")
        XCTAssertEqual(transcriber.segments.map(\.text), ["previous meeting"],
                       "pausing must not touch the transcriber the other drain is reading")

        controller.resumeRecording()
        XCTAssertFalse(controller.isPaused)

        controller.isFinalizingRecording = false
        _ = await session.stop()
    }

    /// `stopBecauseOfSleep` sets the sleep reason and then calls
    /// `stopRecording`. If a stop is already in progress that call is dropped
    /// — and the reason must be dropped with it. Left behind, the next
    /// recording's ORDINARY Stop consumed it: no rename sheet, and a "stopped
    /// because your Mac went to sleep" alert for a sleep that never
    /// interrupted it.
    func test_a_dropped_sleep_stop_does_not_leak_its_reason_into_the_next_stop() async throws {
        let url = try freshWAV("SleepDuringStop")
        await controller.startFakeRecordingForTesting(outputURL: url)

        // A stop is in progress when the sleep notification arrives.
        controller.isStoppingRecording = true
        await controller.stopBecauseOfSleep()
        XCTAssertEqual(session.state, .recording, "the dropped call must not have stopped anything")
        controller.isStoppingRecording = false

        // The next Stop is an ordinary one.
        await controller.stopRecording()
        let saved = try XCTUnwrap(row(for: url))
        XCTAssertNil(controller.sleepInterruption,
                     "an ordinary Stop must not raise the sleep alert")
        XCTAssertEqual(postRecording.pending?.id, saved.id,
                       "an ordinary Stop presents the rename sheet")

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

    }
}
