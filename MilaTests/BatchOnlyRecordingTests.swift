import Combine
import XCTest
import MilaKit
import TranscriptionCore
@testable import Mila

@MainActor
final class BatchOnlyRecordingTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var store: RecordingStore!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var session: RecordingSession!
    private var settings: PostRecordingSettings!
    private var postRecording: PostRecordingCoordinator!
    private var transcriber: LiveTranscriber!
    private var ai: LiveAISession!
    private var controller: QuickActionsController!

    override func setUp() async throws {
        try await super.setUp()
        suite = "BatchOnlyRecordingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        root = TestSupport.makeTempRoot(label: suite)
        store = RecordingStore(rootDirectory: root)
        try FileManager.default.createDirectory(at: store.recordingsDirectory, withIntermediateDirectories: true)
        let manager = TestSupport.isolatedModelManager(modelsDirectory: root.appendingPathComponent("Models"), label: suite)
        try TestSupport.installFakeModel(into: manager)
        let diarization = DiarizationSettings(defaults: defaults)
        diarization.isEnabled = false
        stub = StubWhisperEngine()
        service = TranscriptionService(store: store, modelManager: manager,
            diarizationSettings: diarization,
            remoteSettings: TestSupport.isolatedRemoteSettings(label: suite), engine: stub)
        let llm = LLMSettings(defaults: defaults)
        postRecording = PostRecordingCoordinator(store: store, transcription: service, llm: llm)
        session = RecordingSession()
        controller = QuickActionsController(session: session, store: store, transcription: service,
            languageSettings: RecordingLanguageSettings(defaults: defaults), postRecording: postRecording)
        settings = PostRecordingSettings(defaults: defaults)
        controller.postRecordingSettings = settings
        let liveSettings = LiveAISettings(defaults: defaults)
        liveSettings.useVAD = true
        controller.liveAISettings = liveSettings
        transcriber = LiveTranscriber(transcription: service)
        transcriber.chunkSeconds = 3600
        controller.liveTranscriber = transcriber
        ai = LiveAISession(llmSettings: llm, liveAISettings: liveSettings)
        controller.liveAISession = ai
    }

    override func tearDown() async throws {
        transcriber?.stop()
        ai?.cancel()
        if controller?.isRecording == true { await controller.stopRecording() }
        await controller?.awaitFinalizeTails()
        await service?.waitForIdle()
        if let root { try? FileManager.default.removeItem(at: root) }
        if let suite {
            for name in [suite, suite + ".models", suite + ".remote"] {
                UserDefaults.standard.removePersistentDomain(forName: name)
            }
        }
        try await super.tearDown()
    }

    private func start(batch: Bool) async throws {
        settings.batchOnly = batch
        let url = store.freshAudioURL(suggestedName: "Test Recording")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.6)
        await controller.startFakeRecordingForTesting(outputURL: url)
    }

    private func finish() async {
        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
    }

    private func seed(_ text: String = "previous private meeting") {
        transcriber.seedForTesting([LiveSegment(id: UUID(), startSeconds: 0, endSeconds: 1,
            text: text, speaker: "SPEAKER_00", stable: true)])
        transcriber.speakerNames = ["SPEAKER_00": "Previous speaker"]
        ai.seedForTesting(summary: text, actionItems: [ActionItem(id: UUID().uuidString,
            text: text, speaker: nil, timestampSeconds: 0, source: .llmInferred, addedAt: Date())])
    }

    func test_new_capture_clears_previous_state_before_recording_is_published() async throws {
        seed()
        transcriber.useVAD = true
        transcriber.removeSegment(id: try XCTUnwrap(transcriber.segments.first).id)
        var observedRecording = false
        let observer = session.$state.sink { [self] state in
            guard state == .recording else { return }
            observedRecording = true
            XCTAssertTrue(controller.capturedBatchOnly)
            XCTAssertTrue(transcriber.segments.isEmpty)
            XCTAssertTrue(transcriber.speakerNames.isEmpty)
            XCTAssertFalse(transcriber.hasUserDeletedSegments)
            XCTAssertFalse(transcriber.useVAD)
            XCTAssertTrue(ai.summary.isEmpty)
            XCTAssertTrue(ai.actionItems.isEmpty)
            XCTAssertNil(session.onLiveSamples)
        }
        defer { observer.cancel() }
        try await start(batch: true)
        XCTAssertTrue(observedRecording)
        await finish()
    }

    func test_batch_save_rejects_stale_live_state_and_persists_fresh_transcript() async throws {
        try await start(batch: true)
        // Even a delayed writer contaminating live state cannot make it authoritative.
        seed()
        transcriber.useVAD = true
        var initial: Recording?
        let observer = store.$recordings.sink { rows in
            if initial == nil { initial = rows.first }
        }
        defer { observer.cancel() }
        var finalizedLive = false
        controller.onRecordingFinalized = { _, _ in finalizedLive = true }
        await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 0.5, text: "fresh batch transcript")])
        await finish()
        let first = try XCTUnwrap(initial)
        XCTAssertEqual(first.status, .pending)
        XCTAssertTrue(first.segments.isEmpty)
        XCTAssertTrue(first.fullText.isEmpty)
        XCTAssertNil(first.summary)
        XCTAssertNil(first.actionItems)
        let saved = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertEqual(saved.fullText, "fresh batch transcript")
        XCTAssertTrue(saved.speakerNames.isEmpty)
        XCTAssertFalse(finalizedLive)
        XCTAssertNil(postRecording.pending)
        XCTAssertEqual(controller.revealRecordingID, saved.id)
        let text = try String(contentsOf: store.transcriptURL(for: saved), encoding: .utf8)
        XCTAssertTrue(text.contains("fresh batch transcript"))
        XCTAssertFalse(text.contains("previous private meeting"))
        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 1)
    }

    func test_preference_changes_apply_only_to_next_recording_in_both_directions() async throws {
        try await start(batch: true)
        settings.batchOnly = false
        XCTAssertTrue(controller.capturedBatchOnly)
        await finish()
        XCTAssertNil(postRecording.pending)
        try await start(batch: false)
        seed("current live transcript")
        settings.batchOnly = true
        XCTAssertFalse(controller.capturedBatchOnly)
        await finish()
        XCTAssertEqual(store.recordings.first?.fullText, "current live transcript")
        XCTAssertNotNil(postRecording.pending)
        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 1, "Only the batch recording should use the batch engine")
    }

    func test_live_batch_live_sequence_does_not_reuse_text_or_speaker_names() async throws {
        try await start(batch: false)
        seed("first live recording")
        await finish()
        try await start(batch: true)
        XCTAssertTrue(transcriber.segments.isEmpty)
        await finish()
        XCTAssertEqual(store.recordings.first?.fullText, "stub")
        try await start(batch: false)
        XCTAssertTrue(transcriber.speakerNames.isEmpty)
        seed("third live recording")
        await finish()
        XCTAssertEqual(store.recordings.map(\.fullText), ["third live recording", "stub", "first live recording"])
        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 1)
    }

    func test_switching_preference_does_not_resurrect_deleted_live_transcript() async throws {
        try await start(batch: false)
        seed()
        transcriber.removeSegment(id: try XCTUnwrap(transcriber.segments.first).id)
        settings.batchOnly = true
        await finish()
        let saved = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertTrue(saved.fullText.isEmpty)
        XCTAssertNil(saved.summary)
        XCTAssertNil(saved.actionItems)
        let calls = await stub.transcribeCalls
        XCTAssertTrue(calls.isEmpty)
    }

    func test_pause_and_resume_preserve_mode_and_live_text() async throws {
        try await start(batch: false)
        seed("keep across pause")
        await controller.pauseRecording()
        settings.batchOnly = true
        controller.resumeRecording()
        XCTAssertFalse(controller.capturedBatchOnly)
        XCTAssertEqual(transcriber.fullText, "keep across pause")
        await finish()
    }

    func test_batch_preserves_prepared_title_and_folder() async throws {
        controller.nextRecordingTitle = "User title"
        controller.nextRecordingFolder = "Project notes"
        try await start(batch: true)
        await finish()
        let saved = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(saved.title, "User title")
        XCTAssertEqual(saved.folder, "Project notes")
        XCTAssertTrue(store.folders.contains("Project notes"))
    }

    func test_reset_discards_delayed_fixed_window_result_but_stop_retains_text() async throws {
        seed("retained after stop")
        XCTAssertEqual(transcriber.stop(), "retained after stop")
        XCTAssertEqual(transcriber.fullText, "retained after stop")
        transcriber.start(language: "en")
        transcriber.ingest(ArraySlice(Array(repeating: Float(0.3), count: 32_000)))
        await stub.setDefaultDelay(0.3)
        let pending = Task { await transcriber.transcribeNow() }
        for _ in 0..<100 {
            if !(await stub.transcribeCalls).isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let calls = await stub.transcribeCalls
        XCTAssertEqual(calls.count, 1, "The old transcription must be in flight before reset")
        transcriber.resetSession()
        await pending.value
        XCTAssertTrue(transcriber.fullText.isEmpty)
        XCTAssertTrue(transcriber.segments.isEmpty)
    }
}
