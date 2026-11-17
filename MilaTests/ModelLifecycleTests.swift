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
///  * failures and cancellations still release the retain.
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
            await stub.openUnloadGate()
            await stub.openTranscribeGate(count: 10_000)
        }
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

    // MARK: - Helpers

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
