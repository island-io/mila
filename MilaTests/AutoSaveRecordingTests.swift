import XCTest
import Combine
import TranscriptionCore
@testable import Mila

/// Actual controller Stop tests using only the existing fake-start microphone
/// seam, temporary recordings, stub Whisper and injected title runners.
/// System/app capture shares the production presentation branch; no hardware
/// capture or external LLM is exercised here.
@MainActor
final class AutoSaveRecordingTests: XCTestCase {
    private var tempRoot: URL!
    private var store: RecordingStore!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var session: RecordingSession!
    private var storage: RecordingStorageSettings!
    private var live: LiveAISettings!
    private var transcriber: LiveTranscriber!
    private var llm: LLMSettings!
    private var coordinator: PostRecordingCoordinator!
    private var controller: QuickActionsController!
    private var suites: [String] = []
    private var runLLMInputs: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        suites = []
        runLLMInputs = []
        tempRoot = TestSupport.makeTempRoot(label: "AutoSaveRecordingTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        let manager = ModelManager(
            modelsDirectory: tempRoot.appendingPathComponent("Models"), defaults: isolatedDefaults())
        try TestSupport.installFakeModel(into: manager)
        stub = StubWhisperEngine()
        service = TranscriptionService(
            store: store, modelManager: manager,
            diarizationSettings: DiarizationSettings(defaults: isolatedDefaults()),
            remoteSettings: RemoteTranscriptionSettings(defaults: isolatedDefaults()),
            engine: stub)
        session = RecordingSession()
        storage = RecordingStorageSettings(defaults: isolatedDefaults())
        live = LiveAISettings(defaults: isolatedDefaults(), capabilities: SystemCapabilities(
            modelIdentifier: "Mac15,3", marketingName: "MacBook Pro", isMacBookAir: false,
            physicalRamGB: 32, performanceCoreCount: 10))
        live.enabled = false
        live.transcribeWhileRecording = false
        live.useVAD = true
        transcriber = LiveTranscriber(transcription: service)
        transcriber.useVAD = true
        transcriber.chunkSeconds = 60
        transcriber.windowSeconds = 10
        llm = LLMSettings(defaults: isolatedDefaults(), apiKeyKeychainKey: "AutoSaveRecordingTests.\(UUID())")
        llm.tool = .claude
        llm.nameGenerationEnabled = false
        coordinator = PostRecordingCoordinator(
            store: store, transcription: service, llm: llm,
            runLLM: { [weak self] _, _, transcript, _, _, _, _, _, _, _, _, _, _, _ in
                self?.runLLMInputs.append(transcript)
                return "Generated Title"
            })
        coordinator.transcriptWaitTimeout = 5
        controller = QuickActionsController(
            session: session, store: store, transcription: service,
            languageSettings: RecordingLanguageSettings(defaults: isolatedDefaults()),
            postRecording: coordinator)
        controller.storageSettings = storage
        controller.liveAISettings = live
        controller.liveTranscriber = transcriber
    }

    override func tearDown() async throws {
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
        for id in coordinator.autoSuggestingIDs { coordinator.cancelLLMWork(for: id) }
        transcriber.stop()
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        try await super.tearDown()
    }

    func test_ordinaryStop_presentation_and_saved_transcript_with_live_on_and_off() async throws {
        XCTAssertFalse(storage.autoSaveRecordings)
        for liveOn in [false, true] {
            for autoSave in [false, true] {
                live.transcribeWhileRecording = liveOn
                storage.autoSaveRecordings = autoSave
                let text = "last utterance live=\(liveOn) autoSave=\(autoSave)"
                await stub.setDefaultCanned([TranscriptSegment(start: 0, end: 1, text: text)])
                let callsBefore = await stub.transcribeCalls.count
                let url = try await startFakeRecording()
                XCTAssertEqual(controller.recordingRunsLivePipeline, liveOn)
                if liveOn {
                    // Leave the final audio buffered: Stop must drain it before
                    // marking the live transcript completed, even without a sheet.
                    transcriber.start(language: "en")
                    transcriber.ingest(ArraySlice(Array(repeating: Float(0.3), count: 32_000)))
                    XCTAssertTrue(transcriber.segments.isEmpty)
                }
                await controller.stopRecording()
                let saved = try XCTUnwrap(savedRecording(for: url))
                if liveOn {
                    XCTAssertEqual(saved.status, .completed)
                    XCTAssertEqual(saved.fullText, text, "Stop must flush the final VAD utterance")
                } else {
                    XCTAssertTrue(transcriber.segments.isEmpty, "Live-off must take the batch path")
                }
                if autoSave {
                    XCTAssertNil(coordinator.pending)
                    XCTAssertEqual(controller.autoSaveRevealID, saved.id)
                    XCTAssertEqual(controller.consumeAutoSaveReveal(), saved.id)
                    XCTAssertNil(controller.consumeAutoSaveReveal(), "Reveal must be consumed once")
                } else {
                    XCTAssertEqual(coordinator.pending?.id, saved.id)
                    XCTAssertNil(controller.autoSaveRevealID)
                    coordinator.pending = nil
                }
                await controller.awaitFinalizeTails()
                await service.waitForIdle()
                let final = try XCTUnwrap(savedRecording(for: url))
                XCTAssertEqual(final.status, .completed)
                XCTAssertEqual(final.fullText, text)
                let callsAfter = await stub.transcribeCalls.count
                XCTAssertEqual(callsAfter - callsBefore, 1,
                               "One live drain or one batch pass, without extra transcription")
                XCTAssertTrue(FileManager.default.fileExists(atPath: store.audioURL(for: final).path))
                let restored = RecordingStore(rootDirectory: tempRoot)
                XCTAssertEqual(restored.recordings.first(where: { $0.id == final.id })?.fullText, text)
            }
        }
    }

    func test_preference_is_decided_at_Stop_before_awaiting_session_stop() async throws {
        for atStop in [true, false] {
            storage.autoSaveRecordings = !atStop
            _ = try await startFakeRecording()
            storage.autoSaveRecordings = atStop // Applies at Stop, not record start.
            var flipped = false
            // session.stop publishes .stopping before its capture teardown awaits.
            // This catches moving the preference read below the first await.
            let watch = session.$state.sink { [weak self] state in
                guard state == .stopping else { return }
                flipped = true
                self?.storage.autoSaveRecordings = !atStop
            }
            await controller.stopRecording()
            watch.cancel()
            XCTAssertTrue(flipped)
            XCTAssertEqual(coordinator.pending == nil, atStop)
            XCTAssertEqual(controller.autoSaveRevealID != nil, atStop)
            _ = controller.consumeAutoSaveReveal()
            coordinator.pending = nil
            await controller.awaitFinalizeTails()
            await service.waitForIdle()
        }
    }

    func test_autoSave_keeps_an_already_open_old_sheet() async throws {
        let old = addCompletedRecording()
        coordinator.present(old, titleWasUserProvided: true)
        storage.autoSaveRecordings = true
        let url = try await startFakeRecording()
        await controller.stopRecording()
        let saved = try XCTUnwrap(savedRecording(for: url))
        XCTAssertEqual(coordinator.pending?.id, old.id)
        XCTAssertEqual(controller.consumeAutoSaveReveal(), saved.id)
        XCTAssertEqual(coordinator.pending?.id, old.id, "Reveal must leave the old sheet untouched")
    }

    func test_reveal_skips_trashed_missing_and_autoDropped_rows() async throws {
        storage.autoSaveRecordings = true
        let url = try await startFakeRecording()
        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
        let saved = try XCTUnwrap(savedRecording(for: url))
        store.softDelete(saved)
        XCTAssertNil(controller.consumeAutoSaveReveal())
        XCTAssertNil(controller.autoSaveRevealID)
        controller.autoSaveRevealID = saved.id
        store.permanentlyDelete(saved)
        XCTAssertNil(controller.consumeAutoSaveReveal())
        XCTAssertNil(controller.autoSaveRevealID)

        // Exercise the existing short+empty batch gate and its actual publisher.
        service.shouldAutoDropShortEmpty = { [storage = storage!] duration, text in
            storage.shouldAutoDrop(duration: duration, transcript: text)
        }
        await stub.setDefaultCanned([])
        await stub.setDefaultDelay(0.1)
        var deleted: [UUID] = []
        let watch = store.permanentlyDeleted.sink { deleted += $0 }
        defer { watch.cancel() }
        let emptyURL = try await startFakeRecording()
        await controller.stopRecording()
        let empty = try XCTUnwrap(savedRecording(for: emptyURL))
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
        XCTAssertNil(savedRecording(for: emptyURL))
        XCTAssertEqual(deleted, [empty.id])
        XCTAssertNil(controller.consumeAutoSaveReveal())
        XCTAssertNil(controller.autoSaveRevealID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyURL.path))
    }

    func test_sleepStop_preserves_interruption_without_sheet_reveal_or_title_job() async throws {
        storage.autoSaveRecordings = true
        llm.nameGenerationEnabled = true
        let url = try await startFakeRecording()
        await controller.stopBecauseOfSleep()
        let saved = try XCTUnwrap(savedRecording(for: url))
        XCTAssertEqual(controller.sleepInterruption?.recordingID, saved.id)
        XCTAssertNil(controller.autoSaveRevealID)
        XCTAssertNil(coordinator.pending)
        XCTAssertTrue(coordinator.autoSuggestingIDs.isEmpty)
        XCTAssertTrue(runLLMInputs.isEmpty)
    }

    func test_autoSave_background_title_waits_for_batch_transcript_and_clears_loading() async throws {
        storage.autoSaveRecordings = true
        llm.nameGenerationEnabled = true
        await stub.setDefaultDelay(0.3)
        let url = try await startFakeRecording()
        await controller.stopRecording()
        let saved = try XCTUnwrap(savedRecording(for: url))
        XCTAssertNil(coordinator.pending)
        XCTAssertTrue(coordinator.autoSuggestingIDs.contains(saved.id))
        XCTAssertTrue(runLLMInputs.isEmpty, "A pending row is not final title input")
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
        try await waitFor { !self.coordinator.autoSuggestingIDs.contains(saved.id) }
        XCTAssertEqual(runLLMInputs.count, 1)
        XCTAssertTrue(try XCTUnwrap(runLLMInputs.first).contains("stub"))
        XCTAssertEqual(savedRecording(for: url)?.title, "Generated Title")
    }

    func test_autoSave_preserves_prepared_title_and_skips_suggestion() async throws {
        storage.autoSaveRecordings = true
        llm.nameGenerationEnabled = true
        let url = try await startFakeRecording()
        controller.nextRecordingTitle = "Weekly Sync"
        await controller.stopRecording()
        let saved = try XCTUnwrap(savedRecording(for: url))
        XCTAssertEqual(saved.title, "Weekly Sync")
        XCTAssertEqual(controller.consumeAutoSaveReveal(), saved.id)
        XCTAssertNil(coordinator.pending)
        XCTAssertTrue(coordinator.autoSuggestingIDs.isEmpty)
        XCTAssertEqual(controller.nextRecordingTitle, "")
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
        XCTAssertTrue(runLLMInputs.isEmpty)
        XCTAssertEqual(savedRecording(for: url)?.title, "Weekly Sync")
    }

    func test_autoSuggestOnly_honors_configuration_and_feature_gates() {
        let rec = addCompletedRecording()
        coordinator.autoSuggestOnly(rec) // Feature off, provider configured.
        XCTAssertTrue(coordinator.autoSuggestingIDs.isEmpty)
        llm.tool = .none
        llm.nameGenerationEnabled = true
        coordinator.autoSuggestOnly(rec) // Feature on, provider unconfigured.
        XCTAssertTrue(coordinator.autoSuggestingIDs.isEmpty)
        llm.tool = .claude
        coordinator.autoSuggestOnly(rec, titleWasUserProvided: true)
        XCTAssertTrue(coordinator.autoSuggestingIDs.isEmpty)
        XCTAssertNil(coordinator.pending)
    }

    func test_autoSuggestOnly_waits_for_final_speakers_and_leaves_old_sheet_alone() async throws {
        let old = addCompletedRecording()
        coordinator.present(old, titleWasUserProvided: true)
        let rec = addCompletedRecording()
        llm.nameGenerationEnabled = true
        service.beginSpeakerFinalization(rec.id)
        defer { service.endSpeakerFinalization(rec.id) }
        coordinator.autoSuggestOnly(rec)
        XCTAssertTrue(coordinator.autoSuggestingIDs.contains(rec.id))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(runLLMInputs.isEmpty)
        var final = rec
        final.fullText = "final utterance"
        final.segments = [TranscriptSegment(start: 0, end: 1, text: "final utterance", speaker: "SPEAKER_00")]
        final.speakerNames = ["SPEAKER_00": "Dana"]
        store.update(final)
        service.endSpeakerFinalization(rec.id)
        try await waitFor { !self.coordinator.autoSuggestingIDs.contains(rec.id) }
        XCTAssertEqual(runLLMInputs.count, 1)
        let input = try XCTUnwrap(runLLMInputs.first)
        XCTAssertTrue(input.contains("Dana"))
        XCTAssertTrue(input.contains("final utterance"))
        XCTAssertEqual(coordinator.pending?.id, old.id)
    }

    func test_late_title_does_not_overwrite_user_rename() async throws {
        let reply = TitleReply()
        let parked = makeCoordinator(reply: reply)
        llm.nameGenerationEnabled = true
        let rec = addCompletedRecording()
        parked.autoSuggestOnly(rec)
        defer { parked.cancelLLMWork(for: rec.id) }
        try await waitFor { reply.started }
        store.rename(rec, to: "My chosen title")
        reply.result = .success("Late AI title")
        try await waitFor { !parked.autoSuggestingIDs.contains(rec.id) }
        XCTAssertEqual(store.recordings.first(where: { $0.id == rec.id })?.title, "My chosen title")
        XCTAssertNil(parked.pending)
    }

    func test_title_failure_clears_loading_and_keeps_saved_row() async throws {
        let reply = TitleReply()
        let failing = makeCoordinator(reply: reply)
        llm.nameGenerationEnabled = true
        let rec = addCompletedRecording()
        failing.autoSuggestOnly(rec)
        defer { failing.cancelLLMWork(for: rec.id) }
        try await waitFor { reply.started }
        XCTAssertTrue(failing.autoSuggestingIDs.contains(rec.id))
        reply.result = .failure(NSError(domain: "AutoSaveRecordingTests", code: 1))
        try await waitFor { !failing.autoSuggestingIDs.contains(rec.id) }
        XCTAssertEqual(store.recordings.first(where: { $0.id == rec.id })?.title, rec.title)
        XCTAssertNil(failing.pending)
    }

    func test_cancel_and_permanent_delete_stop_title_jobs_without_restoring_data() async throws {
        for delete in [false, true] {
            let reply = TitleReply()
            let parked = makeCoordinator(reply: reply)
            llm.nameGenerationEnabled = true
            let rec = addCompletedRecording()
            parked.autoSuggestOnly(rec)
            defer { parked.cancelLLMWork(for: rec.id) }
            try await waitFor { reply.started }
            if delete { store.permanentlyDelete(rec) }
            else { parked.cancelLLMWork(for: rec.id) }
            XCTAssertFalse(parked.autoSuggestingIDs.contains(rec.id))
            try await waitFor { reply.cancelled }
            reply.result = .success("Too late")
            XCTAssertEqual(store.recordings.first(where: { $0.id == rec.id })?.title,
                           delete ? nil : rec.title)
            XCTAssertNil(parked.pending)
        }
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "AutoSaveRecordingTests.\(UUID())"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func startFakeRecording() async throws -> URL {
        let url = store.freshAudioURL(suggestedName: "AutoSave-\(UUID())")
        try TestSupport.writeStereo48kSineWav(at: url, durationSeconds: 0.4)
        await controller.startFakeRecordingForTesting(outputURL: url)
        XCTAssertTrue(controller.isRecording)
        return url
    }

    private func savedRecording(for audioURL: URL) -> Recording? {
        let stem = audioURL.deletingPathExtension().lastPathComponent
        return store.recordings.first {
            URL(fileURLWithPath: $0.audioFileName).deletingPathExtension().lastPathComponent == stem
        }
    }

    private func addCompletedRecording() -> Recording {
        let rec = Recording(title: "AutoSave", source: .microphone,
                            audioFileName: "\(UUID()).wav", status: .completed,
                            segments: [TranscriptSegment(start: 0, end: 1, text: "hello world")],
                            fullText: "hello world")
        store.add(rec)
        return rec
    }

    private final class TitleReply {
        var started = false
        var cancelled = false
        var result: Result<String, Error>?
    }

    private func makeCoordinator(reply: TitleReply) -> PostRecordingCoordinator {
        let made = PostRecordingCoordinator(
            store: store, transcription: service, llm: llm,
            runLLM: { _, _, _, _, _, _, _, _, _, _, _, _, _, _ in
                reply.started = true
                do {
                    while reply.result == nil { try await Task.sleep(nanoseconds: 10_000_000) }
                    return try reply.result!.get()
                } catch {
                    reply.cancelled = Task.isCancelled
                    throw error
                }
            })
        made.transcriptWaitTimeout = 5
        return made
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for title job")
        throw NSError(domain: "AutoSaveRecordingTests.Timeout", code: 1)
    }
}
