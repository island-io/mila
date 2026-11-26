import XCTest
import TranscriptionCore
@testable import Mila

/// Regressions for batch-only model residency.
///
/// Live transcription OFF used to behave exactly like ON at launch: `prewarm`
/// compiled and held whisper's weights whatever the user chose, and nothing
/// ever handed them back. These tests pin the new contract:
///
///  * batch-only mode does not prewarm;
///  * the first real transcription loads on demand;
///  * the model is released once the queue drains with no other local user;
///  * a later use reloads;
///  * live retention keeps it warm across jobs;
///  * a release can never land between a load and its transcribe, or take the
///    model away from an overlapping one-shot/batch user;
///  * failures and cancellations still release the retain;
///  * a dictation preloads its model when it starts, its final pass reuses
///    it, and it is released once the dictation ends however it ends (#434).
@MainActor
final class ModelLifecycleTests: XCTestCase {

    private var root: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!

    override func setUp() async throws {
        try await super.setUp()
        root = TestSupport.makeTempRoot(label: "ModelLifecycleTests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: root)
        manager = TestSupport.isolatedModelManager(
            modelsDirectory: root.appendingPathComponent("Models"),
            label: "ModelLifecycleTests")
        try TestSupport.installFakeModel(into: manager, model: .ivritLarge)
        try TestSupport.installFakeModel(into: manager, model: .openaiTurbo)

        let diarization = DiarizationSettings(
            defaults: .init(suiteName: "ModelLifecycleTests.diarization")!)
        diarization.isEnabled = false
        stub = StubWhisperEngine()
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: diarization,
            remoteSettings: TestSupport.isolatedRemoteSettings(label: "ModelLifecycleTests"),
            engine: stub)
        // These tests exercise batch-only residency. The service defaults to
        // the historical warm/retained behaviour for hosts that never wire
        // live settings; MilaApp seeds false for batch-only explicitly.
        service.retainsLocalModel = false
    }

    override func tearDown() async throws {
        // Never leave a gated transcribe holding a task into teardown.
        if let stub = stub {
            await stub.openLoadGate()
            await stub.openUnloadGate()
            await stub.openTranscribeGate(count: 10_000)
        }
        // A test that fails between `beginLocalModelHold` and its end would
        // leave the hold's task parked for good, retaining the service, store
        // and stub for the rest of the bundle. Shutdown ends and drains every
        // hold; it is idempotent for tests that already shut down.
        await service?.shutdown()
        if let root = root { try? FileManager.default.removeItem(at: root) }
        try await super.tearDown()
    }

    // MARK: - Settings/session transition matrix

    func test_retentionMatrix_keepsTheModelForARecordingSnapshottedLive() {
        // Live was ON at record start and the user switches it OFF mid-
        // recording. The recording still runs its live pipeline, so its model
        // must stay warm…
        XCTAssertTrue(MilaApp.localModelRetentionRequired(
            livePipelineEnabled: false,
            recordingRunsLivePipeline: true,
            recordingActive: true,
            stoppingOrFinalizing: false,
            remoteActive: false))
        // …through Stop and the finalize/drain window…
        XCTAssertTrue(MilaApp.localModelRetentionRequired(
            livePipelineEnabled: false,
            recordingRunsLivePipeline: true,
            recordingActive: false,
            stoppingOrFinalizing: true,
            remoteActive: false))
        // …and only then, with live still off, may it be released.
        XCTAssertFalse(MilaApp.localModelRetentionRequired(
            livePipelineEnabled: false,
            recordingRunsLivePipeline: true,
            recordingActive: false,
            stoppingOrFinalizing: false,
            remoteActive: false))
    }

    func test_retentionMatrix_batchOnlyNeverPinsTheModel() {
        XCTAssertFalse(MilaApp.localModelRetentionRequired(
            livePipelineEnabled: false,
            recordingRunsLivePipeline: false,
            recordingActive: true,
            stoppingOrFinalizing: false,
            remoteActive: false))
    }

    func test_retentionMatrix_finalizeRetainsEvenWhenTheNewRecordingIsBatchOnly() {
        // Deliberate: since #356 a batch-only recording can start during a
        // live recording's drain and overwrite `recordingRunsLivePipeline`
        // while that drain still needs the model. Finalize alone retains;
        // the release then waits for it to clear.
        XCTAssertTrue(MilaApp.localModelRetentionRequired(
            livePipelineEnabled: false,
            recordingRunsLivePipeline: false,
            recordingActive: true,
            stoppingOrFinalizing: true,
            remoteActive: false))
    }

    // MARK: - Record-start gate

    func test_modelPreparation_blocksRecordStartOnlyForALiveRecording() {
        // Live: a recording started mid-compile would feed a model that is
        // not ready, so the start is refused.
        XCTAssertTrue(QuickActionsController.modelPreparationBlocksRecordStart(
            isPreparingModel: true, nextRecordingRunsLivePipeline: true))
        // Batch-only: the model loads on demand after every Stop (#393). The
        // next recording does not use it until its own batch pass, so the
        // reload must not drop a hotkey or auto-record start.
        XCTAssertFalse(QuickActionsController.modelPreparationBlocksRecordStart(
            isPreparingModel: true, nextRecordingRunsLivePipeline: false))
        XCTAssertFalse(QuickActionsController.modelPreparationBlocksRecordStart(
            isPreparingModel: false, nextRecordingRunsLivePipeline: true))
    }

    func test_retentionMatrix_liveModePinsAndRemoteReleases() {
        XCTAssertTrue(MilaApp.localModelRetentionRequired(
            livePipelineEnabled: true,
            recordingRunsLivePipeline: true,
            recordingActive: false,
            stoppingOrFinalizing: false,
            remoteActive: false))
        XCTAssertFalse(MilaApp.localModelRetentionRequired(
            livePipelineEnabled: true,
            recordingRunsLivePipeline: true,
            recordingActive: true,
            stoppingOrFinalizing: true,
            remoteActive: true))
    }

    // MARK: - Launch prewarm

    func test_batchOnlyModeDoesNotPrewarmAtLaunch() async {
        XCTAssertFalse(service.retainsLocalModel)
        service.prewarm(language: "he")
        // The guard is synchronous, so no load may even be scheduled.
        var loads = await stub.loadCallCount
        XCTAssertEqual(loads, 0)
        try? await Task.sleep(nanoseconds: 100_000_000)
        loads = await stub.loadCallCount
        XCTAssertEqual(loads, 0, "batch-only mode must not load whisper at launch")
        let loaded = await stub.isModelLoaded
        XCTAssertFalse(loaded)
    }

    func test_liveModeStillPrewarms() async {
        service.retainsLocalModel = true
        service.prewarm(language: "he")
        await waitForLoad(1)
        let loaded = await stub.isModelLoaded
        let unloads = await stub.unloadCount
        XCTAssertTrue(loaded)
        XCTAssertEqual(unloads, 0, "live retention must keep the prewarmed model")
    }

    // MARK: - Lazy load, drained release, reload

    func test_firstTranscriptionLoadsLazilyThenReleasesAfterQueueDrains() async throws {
        let fixture = try TestRecordingFixture.make(in: store, title: "Batch", language: "he")
        let initialLoads = await stub.loadCallCount
        XCTAssertEqual(initialLoads, 0)

        service.enqueue(fixture.recording)
        await service.waitForIdle()

        let loads = await stub.loadCallCount
        let unloads = await stub.unloadCount
        let loaded = await stub.isModelLoaded
        XCTAssertEqual(loads, 1, "the first real transcription loads on demand")
        XCTAssertEqual(unloads, 1, "the model is handed back when the queue drains")
        XCTAssertFalse(loaded)
        let saved = try XCTUnwrap(store.recordings.first { $0.id == fixture.recording.id })
        XCTAssertEqual(saved.status, .completed)
    }

    func test_queuedJobsShareOneLoadAndReleaseOnlyAfterTheLast() async throws {
        let first = try TestRecordingFixture.make(in: store, title: "First", language: "he")
        let second = try TestRecordingFixture.make(in: store, title: "Second", language: "he")

        service.enqueue(first.recording)
        service.enqueue(second.recording)
        await service.waitForIdle()

        let requests = await stub.loadRequestCount
        let loads = await stub.loadCallCount
        let unloads = await stub.unloadCount
        XCTAssertEqual(requests, 2, "each job requests the model…")
        XCTAssertEqual(loads, 1, "…but a queued job must not reload it")
        XCTAssertEqual(unloads, 1, "release happens once, after the drain")
    }

    func test_secondUseReloadsAfterAnIdleRelease() async throws {
        let first = try TestRecordingFixture.make(in: store, title: "First", language: "he")
        service.enqueue(first.recording)
        await service.waitForIdle()
        var loads = await stub.loadCallCount
        var unloads = await stub.unloadCount
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(unloads, 1)

        let second = try TestRecordingFixture.make(in: store, title: "Second", language: "he")
        service.enqueue(second.recording)
        await service.waitForIdle()
        loads = await stub.loadCallCount
        unloads = await stub.unloadCount
        XCTAssertEqual(loads, 2, "a released model must load again on the next use")
        XCTAssertEqual(unloads, 2)
    }

    // MARK: - Live retention

    func test_liveRetentionKeepsModelWarmAcrossJobs() async throws {
        service.retainsLocalModel = true
        let fixture = try TestRecordingFixture.make(in: store, title: "Live", language: "he")
        service.enqueue(fixture.recording)
        await service.waitForIdle()

        let loads = await stub.loadCallCount
        let unloads = await stub.unloadCount
        let loaded = await stub.isModelLoaded
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(unloads, 0, "live mode keeps the model resident")
        XCTAssertTrue(loaded)
    }

    func test_turningRetentionOffReleasesAnIdleWarmModel() async throws {
        service.retainsLocalModel = true
        let fixture = try TestRecordingFixture.make(in: store, title: "Warm", language: "he")
        service.enqueue(fixture.recording)
        await service.waitForIdle()
        var unloads = await stub.unloadCount
        XCTAssertEqual(unloads, 0)

        await service.updateLocalModelRetention(false).value
        unloads = await stub.unloadCount
        let loaded = await stub.isModelLoaded
        XCTAssertEqual(unloads, 1)
        XCTAssertFalse(loaded)
    }

    func test_retentionOffDuringAUseWaitsForThatUseToFinish() async throws {
        service.retainsLocalModel = true
        let warmup = try TestRecordingFixture.make(in: store, title: "Warmup", language: "en")
        service.enqueue(warmup.recording)
        await service.waitForIdle()

        await stub.closeTranscribeGate()
        let baseline = await stub.transcribeEnteredCount
        let svc = service!
        let samples = noisySamples
        let oneShot = Task { await svc.transcribeOnce(samples: samples, language: "en") }
        await stub.waitUntilTranscribeEntered(baseline + 1)

        await service.updateLocalModelRetention(false).value
        var unloads = await stub.unloadCount
        var loaded = await stub.isModelLoaded
        XCTAssertEqual(unloads, 0, "a release must not land under an in-flight transcribe")
        XCTAssertTrue(loaded)

        await stub.openTranscribeGate(count: 1)
        _ = await oneShot.value
        await service.waitForIdle()
        unloads = await stub.unloadCount
        loaded = await stub.isModelLoaded
        XCTAssertEqual(unloads, 1, "the model is released once the last user finishes")
        XCTAssertFalse(loaded)
    }

    // MARK: - Overlap

    func test_overlappingOneShotAndBatchKeepTheModelUntilBothFinish() async throws {
        await stub.closeTranscribeGate()
        let fixture = try TestRecordingFixture.make(in: store, title: "Batch", language: "he")
        service.enqueue(fixture.recording)
        await stub.waitUntilTranscribeEntered(1)

        let svc = service!
        let samples = noisySamples
        let oneShot = Task { await svc.transcribeOnce(samples: samples, language: "he") }
        await stub.waitUntilTranscribeEntered(2)
        let maxConcurrent = await stub.maxConcurrentInFlight
        XCTAssertGreaterThanOrEqual(maxConcurrent, 2,
                                    "test setup must actually overlap the two users")

        // Let the batch finish first; the one-shot still holds the model.
        await stub.openTranscribeGate(count: 1)
        await service.waitForIdle()
        var unloads = await stub.unloadCount
        var loaded = await stub.isModelLoaded
        XCTAssertEqual(unloads, 0, "ending one user must not discard another user's model")
        XCTAssertTrue(loaded)

        await stub.openTranscribeGate(count: 1)
        _ = await oneShot.value
        await service.waitForIdle()
        unloads = await stub.unloadCount
        loaded = await stub.isModelLoaded
        XCTAssertEqual(unloads, 1)
        XCTAssertFalse(loaded)
    }

    func test_newUseWaitsForAnUnloadingModelBeforeLoading() async throws {
        service.retainsLocalModel = true
        _ = await service.transcribeOnce(samples: noisySamples, language: "en")
        await stub.closeUnloadGate()
        let firstRelease = service.updateLocalModelRetention(false)
        let deadline = Date().addingTimeInterval(10)
        while await stub.unloadEnteredCount == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let entered = await stub.unloadEnteredCount
        XCTAssertEqual(entered, 1, "setup must hold an actual unload in flight")
        let baselineRequests = await stub.loadRequestCount
        let svc = service!
        let samples = noisySamples
        let started = expectation(description: "new user started during unload")
        let oneShot = Task {
            started.fulfill()
            return await svc.transcribeOnce(samples: samples, language: "en")
        }
        // A second cleanup caller must also join, rather than enqueueing an
        // unload that can overtake this new user's load/transcribe pair.
        let secondRelease = service.updateLocalModelRetention(false)
        await fulfillment(of: [started], timeout: 10)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let requestsDuringRelease = await stub.loadRequestCount
        XCTAssertEqual(requestsDuringRelease, baselineRequests,
                       "no load may enter an engine whose unload is suspended")

        await stub.openUnloadGate()
        await firstRelease.value
        await secondRelease.value
        let text = await oneShot.value
        XCTAssertEqual(text, "stub")
        let loaded = await stub.isModelLoaded
        let unloads = await stub.unloadCount
        XCTAssertFalse(loaded)
        XCTAssertEqual(unloads, 2, "only the original and the new user's final release")
    }

    func test_rapidRetentionChangesKeepTheLatestDecision() async {
        service.retainsLocalModel = true
        _ = await service.transcribeOnce(samples: noisySamples, language: "en")
        // Both changes happen synchronously before either cleanup task runs.
        // OFF's cleanup must consult the latest ON preference, not replay OFF.
        let off = service.updateLocalModelRetention(false)
        let on = service.updateLocalModelRetention(true)
        XCTAssertTrue(service.retainsLocalModel)
        await off.value
        await on.value
        let loaded = await stub.isModelLoaded
        let unloads = await stub.unloadCount
        XCTAssertTrue(loaded)
        XCTAssertEqual(unloads, 0)

        let nextOn = service.updateLocalModelRetention(true)
        let finalOff = service.updateLocalModelRetention(false)
        XCTAssertFalse(service.retainsLocalModel)
        await nextOn.value
        await finalOff.value
        let finalLoaded = await stub.isModelLoaded
        XCTAssertFalse(finalLoaded)
    }

    /// A prewarm that arrives while a release is still running waits for it,
    /// and must check again before loading: if retention went back off while
    /// it waited, nobody wants the model, and a load (up to a ~13 s CoreML
    /// compile) would only be freed again straight away.
    func test_prewarmThatWaitedOnAReleaseDoesNotLoadOnceRetentionIsOff() async throws {
        service.retainsLocalModel = true
        _ = await service.transcribeOnce(samples: noisySamples, language: "en")
        await stub.closeUnloadGate()
        let release = service.updateLocalModelRetention(false)
        let deadline = Date().addingTimeInterval(10)
        while await stub.unloadEnteredCount == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let entered = await stub.unloadEnteredCount
        XCTAssertEqual(entered, 1, "setup must hold an actual unload in flight")

        // Retention back on: the prewarm passes its first check and queues
        // behind the release in flight. Being counted as a user is the proof
        // it got that far; the closed unload gate holds it there.
        let on = service.updateLocalModelRetention(true)
        service.prewarm(language: "he")
        let queuedBy = Date().addingTimeInterval(10)
        while service.localModelUserCountForTesting == 0, Date() < queuedBy {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(service.localModelUserCountForTesting, 1,
                       "setup must queue the prewarm behind the release in flight")
        let baselineRequests = await stub.loadRequestCount

        // ...and off again before that release finishes.
        let off = service.updateLocalModelRetention(false)
        await stub.openUnloadGate()
        await release.value
        await on.value
        await off.value
        await service.waitForPrewarmsForTesting()

        let requests = await stub.loadRequestCount
        let loaded = await stub.isModelLoaded
        XCTAssertEqual(requests, baselineRequests, "the prewarm loaded a model nobody retains any more")
        XCTAssertFalse(loaded)
    }

    // MARK: - Failure and cancellation

    func test_failedUseReleasesTheModel() async {
        await stub.setNextError(LifecycleBoom())
        let text = await service.transcribeOnce(samples: noisySamples, language: "en")
        let unloads = await stub.unloadCount
        let loaded = await stub.isModelLoaded
        XCTAssertEqual(text, "")
        XCTAssertEqual(unloads, 1, "a failed local use must not strand the model")
        XCTAssertFalse(loaded)
    }

    func test_cancelledUseReleasesTheModelWithoutAnError() async {
        await stub.setNextError(CancellationError())
        let text = await service.transcribeOnce(samples: noisySamples, language: "en")
        let unloads = await stub.unloadCount
        let loaded = await stub.isModelLoaded
        XCTAssertEqual(text, "")
        XCTAssertNil(service.lastError)
        XCTAssertEqual(unloads, 1, "a cancelled local use must not strand the model")
        XCTAssertFalse(loaded)
    }

    // MARK: - Dictation preload (#434)
    //
    // `DictationController` begins a hold when a start is accepted and ends it
    // after its final `transcribeOnce`, or on cancel / a failed start. These
    // drive the same calls in the same order without a microphone.

    func test_dictationHold_preloadsTheDictationModelAsSoonAsItBegins() async throws {
        let hold = try XCTUnwrap(service.beginLocalModelHold(language: "he"),
                                 "batch-only mode must preload for dictation")
        XCTAssertEqual(service.localModelUserCountForTesting, 1,
                       "the hold is counted before begin returns, so no release can start under it")
        await waitForLoad(1)
        let loaded = await stub.isModelLoaded
        let model = await stub.loadedModel
        let hebrew = try XCTUnwrap(manager.model(for: "he"))
        XCTAssertTrue(loaded, "the model loads while the user is still speaking")
        XCTAssertEqual(model?.lastPathComponent, manager.url(for: hebrew).lastPathComponent,
                       "the preload warms the model the final pass resolves for the language")
        let transcribes = await stub.transcribeEnteredCount
        XCTAssertEqual(transcribes, 0, "a preload loads only")

        await service.endLocalModelHold(hold)?.value
    }

    func test_dictationFinalPassReusesThePreloadAndTheEndReleasesIt() async throws {
        let hold = try XCTUnwrap(service.beginLocalModelHold(language: "he"))
        await waitForLoad(1)

        let text = await service.transcribeOnce(samples: noisySamples, language: "he")
        XCTAssertEqual(text, "stub")
        let requests = await stub.loadRequestCount
        let loads = await stub.loadCallCount
        var unloads = await stub.unloadCount
        var loaded = await stub.isModelLoaded
        XCTAssertEqual(requests, 2, "the final pass still asks for the model…")
        XCTAssertEqual(loads, 1, "…but must not load it a second time")
        XCTAssertEqual(unloads, 0, "the final pass ending must not release a model the dictation still holds")
        XCTAssertTrue(loaded)

        await service.endLocalModelHold(hold)?.value
        unloads = await stub.unloadCount
        loaded = await stub.isModelLoaded
        XCTAssertEqual(unloads, 1, "batch-only mode releases the model once the dictation ends")
        XCTAssertFalse(loaded)
        XCTAssertEqual(service.localModelUserCountForTesting, 0)
    }

    /// The second press can come before a large model has finished loading.
    /// The final pass must wait for the preload rather than load again, and
    /// the hold keeps the model through it.
    func test_dictationStoppedBeforeThePreloadFinishesWaitsForItInsteadOfReloading() async throws {
        await stub.closeLoadGate()
        let hold = try XCTUnwrap(service.beginLocalModelHold(language: "he"))
        await waitForLoad(1)

        let svc = service!
        let samples = noisySamples
        let finalPass = Task { await svc.transcribeOnce(samples: samples, language: "he") }
        let deadline = Date().addingTimeInterval(10)
        while await stub.callsWaitingBehindHeldLoad == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let queued = await stub.callsWaitingBehindHeldLoad
        XCTAssertEqual(queued, 1, "setup must queue the final pass behind the preload in progress")

        await stub.openLoadGate()
        let text = await finalPass.value
        XCTAssertEqual(text, "stub")
        let loads = await stub.loadCallCount
        var unloads = await stub.unloadCount
        XCTAssertEqual(loads, 1, "one load per dictation, even when stopped mid-preload")
        XCTAssertEqual(unloads, 0)

        await service.endLocalModelHold(hold)?.value
        unloads = await stub.unloadCount
        let duringLoad = await stub.unloadsDuringLoad
        XCTAssertEqual(unloads, 1)
        XCTAssertEqual(duringLoad, 0)
    }

    func test_cancelledDictationReleasesThePreloadedModel() async throws {
        let hold = try XCTUnwrap(service.beginLocalModelHold(language: "en"))
        await waitForLoad(1)

        // Cancel (or a start that failed after the hold was taken): the hold
        // ends with no final pass.
        await service.endLocalModelHold(hold)?.value
        let unloads = await stub.unloadCount
        let loaded = await stub.isModelLoaded
        let transcribes = await stub.transcribeEnteredCount
        XCTAssertEqual(unloads, 1, "a cancelled dictation must not strand the model")
        XCTAssertFalse(loaded)
        XCTAssertEqual(transcribes, 0)
        XCTAssertEqual(service.localModelUserCountForTesting, 0)
    }

    /// A dictation cancelled while a large model is still loading: the load
    /// cannot be interrupted, so the use must outlive the end until the load
    /// returns. Releasing at the end itself would queue an unload beside the
    /// load — the straddle the lifetime rules forbid.
    func test_dictationEndedMidPreloadReleasesOnlyAfterTheLoadReturns() async throws {
        await stub.closeLoadGate()
        let hold = try XCTUnwrap(service.beginLocalModelHold(language: "he"))
        await waitForLoad(1)

        let ending = service.endLocalModelHold(hold)
        XCTAssertNotNil(ending, "the hold is still winding down while its load is held")
        try? await Task.sleep(nanoseconds: 100_000_000)
        var unloads = await stub.unloadCount
        var duringLoad = await stub.unloadsDuringLoad
        XCTAssertEqual(unloads, 0)
        XCTAssertEqual(duringLoad, 0, "no unload may be issued while the preload is loading")
        XCTAssertEqual(service.localModelUserCountForTesting, 1,
                       "the hold's use lasts until its load has returned")

        await stub.openLoadGate()
        await ending?.value
        unloads = await stub.unloadCount
        duringLoad = await stub.unloadsDuringLoad
        let loaded = await stub.isModelLoaded
        XCTAssertEqual(unloads, 1, "the model is released once the load it was ended during returns")
        XCTAssertEqual(duringLoad, 0)
        XCTAssertFalse(loaded)
    }

    /// A dictation that starts while an idle release is still unloading goes
    /// through the same admission as every other user: no preload may enter
    /// an engine whose unload is suspended.
    func test_dictationHoldWaitsForAnInFlightReleaseBeforePreloading() async throws {
        try await holdAReleaseInFlight()
        let baselineRequests = await stub.loadRequestCount

        let hold = try XCTUnwrap(service.beginLocalModelHold(language: "en"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        let requestsDuringRelease = await stub.loadRequestCount
        XCTAssertEqual(requestsDuringRelease, baselineRequests,
                       "the preload must wait for the release in flight to finish")

        await stub.openUnloadGate()
        await waitForLoad(2)
        let loaded = await stub.isModelLoaded
        XCTAssertTrue(loaded, "admitted after the release, the preload loads the model again")

        await service.endLocalModelHold(hold)?.value
        let unloads = await stub.unloadCount
        let finalLoaded = await stub.isModelLoaded
        XCTAssertEqual(unloads, 2, "the original release, then the dictation's own")
        XCTAssertFalse(finalLoaded)
    }

    /// A start that fails (mic refused, engine bring-up error) while its hold
    /// is still queued behind a release must not load anything afterwards.
    func test_dictationHoldEndedBeforeAdmissionNeverLoads() async throws {
        try await holdAReleaseInFlight()
        let baselineRequests = await stub.loadRequestCount

        let hold = try XCTUnwrap(service.beginLocalModelHold(language: "en"))
        let ending = service.endLocalModelHold(hold)
        await stub.openUnloadGate()
        await ending?.value
        await service.waitForIdle()

        let requests = await stub.loadRequestCount
        let loaded = await stub.isModelLoaded
        XCTAssertEqual(requests, baselineRequests, "an ended hold must not preload")
        XCTAssertFalse(loaded)
        XCTAssertEqual(service.localModelUserCountForTesting, 0)
    }

    /// Ending the same hold twice must not take a second user's count: here
    /// that would release the model under an in-flight one-shot transcribe.
    func test_endingADictationHoldTwiceDoesNotDropAnotherUsersRetain() async throws {
        let hold = try XCTUnwrap(service.beginLocalModelHold(language: "en"))
        await waitForLoad(1)
        await stub.closeTranscribeGate()
        let svc = service!
        let samples = noisySamples
        let oneShot = Task { await svc.transcribeOnce(samples: samples, language: "en") }
        await stub.waitUntilTranscribeEntered(1)
        XCTAssertEqual(service.localModelUserCountForTesting, 2)

        await service.endLocalModelHold(hold)?.value
        XCTAssertNil(service.endLocalModelHold(hold), "a second end is a no-op")
        XCTAssertEqual(service.localModelUserCountForTesting, 1,
                       "only the in-flight transcribe is still counted")
        var unloads = await stub.unloadCount
        XCTAssertEqual(unloads, 0, "the model must survive under the in-flight transcribe")

        await stub.openTranscribeGate(count: 1)
        _ = await oneShot.value
        await service.waitForIdle()
        unloads = await stub.unloadCount
        XCTAssertEqual(unloads, 1)
    }

    /// Live mode (`retainsLocalModel`) must behave exactly as before: no
    /// hold, no extra load at dictation start, and the warm model stays.
    func test_liveModeTakesNoDictationHold() async throws {
        service.retainsLocalModel = true
        XCTAssertNil(service.beginLocalModelHold(language: "he"))
        XCTAssertEqual(service.localModelUserCountForTesting, 0)
        try? await Task.sleep(nanoseconds: 100_000_000)
        var requests = await stub.loadRequestCount
        XCTAssertEqual(requests, 0, "live mode must not load anything at dictation start")

        let text = await service.transcribeOnce(samples: noisySamples, language: "he")
        XCTAssertEqual(text, "stub")
        await service.waitForIdle()
        requests = await stub.loadRequestCount
        let unloads = await stub.unloadCount
        let loaded = await stub.isModelLoaded
        XCTAssertEqual(requests, 1, "the final pass loads on demand, as in live mode before")
        XCTAssertEqual(unloads, 0, "live mode keeps the model warm after a dictation")
        XCTAssertTrue(loaded)
    }

    func test_remoteBackendTakesNoDictationHold() async throws {
        let suiteName = "ModelLifecycleTests.remote.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let remote = RemoteTranscriptionSettings(defaults: suite,
                                                 apiKeyKeychainKey: suiteName + ".unused-key")
        remote.backend = .remote
        let remoteStub = StubWhisperEngine()
        let remoteService = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(
                defaults: .init(suiteName: "ModelLifecycleTests.diarization")!),
            remoteSettings: remote,
            engine: remoteStub)
        remoteService.retainsLocalModel = false

        XCTAssertNil(remoteService.beginLocalModelHold(language: "he"),
                     "the remote backend never touches the local engine")
        XCTAssertEqual(remoteService.localModelUserCountForTesting, 0)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let requests = await remoteStub.loadRequestCount
        XCTAssertEqual(requests, 0)
        await remoteService.shutdown()
    }

    /// A batch job is between its own load and transcribe while a dictation
    /// in another language starts. The engine keeps one context, so a
    /// preload queued there would swap the model under the job. With anyone
    /// else mid-flight the dictation leaves the load to its final pass, and
    /// its hold still keeps the model from being released when the job ends.
    func test_dictationHoldSkipsThePreloadWhileAnotherLocalUserIsActive() async throws {
        await stub.closeTranscribeGate()
        let fixture = try TestRecordingFixture.make(in: store, title: "Batch", language: "he")
        service.enqueue(fixture.recording)
        await stub.waitUntilTranscribeEntered(1)
        let jobRequests = await stub.loadRequestCount
        XCTAssertEqual(jobRequests, 1, "setup: the job has loaded its model")

        let hold = try XCTUnwrap(service.beginLocalModelHold(language: "en"))
        XCTAssertEqual(service.localModelUserCountForTesting, 2)
        try? await Task.sleep(nanoseconds: 100_000_000)
        var requests = await stub.loadRequestCount
        let hebrew = try XCTUnwrap(manager.model(for: "he"))
        var model = await stub.loadedModel
        XCTAssertEqual(requests, jobRequests, "no preload while another local user is mid-flight")
        XCTAssertEqual(model?.lastPathComponent, manager.url(for: hebrew).lastPathComponent,
                       "the job's model must still be the one loaded")

        await stub.openTranscribeGate(count: 1)
        await service.waitForIdle()
        var unloads = await stub.unloadCount
        XCTAssertEqual(unloads, 0, "the dictation's hold keeps the model past the job's end")

        // The final pass then loads its own model on demand, as before.
        let text = await service.transcribeOnce(samples: noisySamples, language: "en")
        XCTAssertEqual(text, "stub")
        requests = await stub.loadRequestCount
        model = await stub.loadedModel
        let english = try XCTUnwrap(manager.model(for: "en"))
        XCTAssertEqual(requests, jobRequests + 1)
        XCTAssertEqual(model?.lastPathComponent, manager.url(for: english).lastPathComponent)

        await service.endLocalModelHold(hold)?.value
        unloads = await stub.unloadCount
        XCTAssertEqual(unloads, 1, "released once the dictation ends")
    }

    func test_dictationHoldIsRefusedWhenNoModelIsInstalled() throws {
        // `model(for:)` falls back to any installed selected model, so the
        // final pass skips only when nothing usable is installed at all.
        for model in [WhisperModel.ivritLarge, .openaiTurbo] {
            try FileManager.default.removeItem(at: manager.url(for: model))
        }
        manager.refreshInstalled()
        let resolved = manager.model(for: "he")
        XCTAssertFalse(resolved.map { manager.isInstalled($0) } ?? false,
                       "setup must leave Hebrew with no installed model")
        XCTAssertNil(service.beginLocalModelHold(language: "he"),
                     "nothing to preload when the final pass would skip")
        XCTAssertEqual(service.localModelUserCountForTesting, 0)
    }

    /// Quitting mid-dictation: shutdown ends the hold itself, and frees the
    /// engine only after a preload still loading has returned — a late load
    /// would otherwise recreate the context after teardown.
    func test_shutdownEndsADictationHoldAndWaitsForItsPreload() async throws {
        await stub.closeLoadGate()
        let hold = try XCTUnwrap(service.beginLocalModelHold(language: "he"))
        await waitForLoad(1)

        let svc = service!
        let down = Task { await svc.shutdown() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        var shutdowns = await stub.shutdownCount
        XCTAssertEqual(shutdowns, 0, "the engine must not be torn down under a preload")

        await stub.openLoadGate()
        await down.value
        shutdowns = await stub.shutdownCount
        let loaded = await stub.isModelLoaded
        XCTAssertEqual(shutdowns, 1)
        XCTAssertFalse(loaded, "nothing may be left loaded after shutdown")
        XCTAssertNil(service.endLocalModelHold(hold),
                     "the dictation's own end after shutdown is a no-op")
        XCTAssertNil(service.beginLocalModelHold(language: "he"),
                     "no new hold once the service is shutting down")
    }

    // MARK: - Helpers

    /// Warm the model with retention on, then switch retention off with the
    /// unload gate closed, so a release is suspended inside `engine.unload()`
    /// when this returns. The caller opens the gate.
    private func holdAReleaseInFlight() async throws {
        service.retainsLocalModel = true
        _ = await service.transcribeOnce(samples: noisySamples, language: "en")
        await stub.closeUnloadGate()
        service.updateLocalModelRetention(false)
        let deadline = Date().addingTimeInterval(10)
        while await stub.unloadEnteredCount == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let entered = await stub.unloadEnteredCount
        XCTAssertEqual(entered, 1, "setup must hold an actual unload in flight")
    }

    private var noisySamples: [Float] {
        Array(repeating: Float(0.2), count: 16_000)
    }

    private func waitForLoad(_ target: Int, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let loads = await stub.loadCallCount
            if loads >= target { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for \(target) actual model load(s)")
    }
}

private struct LifecycleBoom: Error {}
