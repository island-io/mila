import XCTest
import TranscriptionCore
@testable import Mila

/// Same public entry points as dictation and the saved-recording queue.
/// This regression runs against both the original and corrected service.
@MainActor
final class TranscriptionServiceShutdownTests: XCTestCase {
    func test_shutdown_rejects_new_one_shot_work() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.cleanUp() }
        await fixture.service.shutdown()
        let segments = await fixture.service.transcribeOnceSegments(
            samples: Array(repeating: Float(0.2), count: 16_000),
            language: "en", audioCtx: 0)
        XCTAssertTrue(segments.isEmpty, "Shutdown must reject dictation/live work")
        let calls = await fixture.remote.calls
        XCTAssertEqual(calls, 0, "No remote transcription may start after shutdown")
        XCTAssertNil(fixture.service.lastError)
    }

    func test_shutdown_keeps_later_enqueued_recording_recoverable() async throws {
        let fixture = try AdmissionFixture()
        defer { fixture.cleanUp() }
        let audioURL = fixture.store.recordingsDirectory.appendingPathComponent("shutdown.wav")
        try TestSupport.writeSineWav(at: audioURL)
        let recording = Recording(title: "Shutdown regression", source: .microphone,
                                  audioFileName: audioURL.lastPathComponent, status: .pending, language: "en")
        fixture.store.add(recording)
        await fixture.service.shutdown()
        fixture.service.enqueue(recording)
        await fixture.service.waitForIdle(timeout: 10)
        let calls = await fixture.remote.calls
        XCTAssertEqual(calls, 0, "Queue admission must close on shutdown")
        let saved = try XCTUnwrap(fixture.store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(saved.status, .pending, "Untouched queued audio must remain eligible for launch recovery")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.store.audioURL(for: saved).path))
        XCTAssertNil(fixture.service.lastError)
    }
}

@MainActor
private struct AdmissionFixture {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let store: RecordingStore
    let remote: AdmissionProbeRemoteEngine
    let service: TranscriptionService

    init() throws {
        root = TestSupport.makeTempRoot(label: "ShutdownAdmission")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "ShutdownAdmission.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = RecordingStore(rootDirectory: root)
        let settings = RemoteTranscriptionSettings(defaults: defaults,
                                                   apiKeyKeychainKey: suiteName + ".unused-key")
        settings.endpoint = "http://localhost:8080/v1"
        settings.model = "whisper-1"
        settings.backend = .remote
        remote = AdmissionProbeRemoteEngine()
        service = TranscriptionService(
            store: store,
            modelManager: ModelManager(modelsDirectory: root.appendingPathComponent("Models"), defaults: defaults),
            diarizationSettings: DiarizationSettings(defaults: defaults),
            remoteSettings: settings, engine: StubWhisperEngine(), remoteEngine: remote)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor AdmissionProbeRemoteEngine: RemoteTranscribing {
    private(set) var calls = 0
    func configure(_ config: RemoteTranscriptionConfig) async {}
    func loadIfNeeded(modelURL: URL, displayName: String) async throws {}
    func shutdown() async {}
    func transcribe(samples: [Float], language: String, audioCtx: Int32?,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        calls += 1
        // Empty avoids unrelated post-success compression while demonstrating
        // that the original service has nevertheless started remote work.
        return []
    }
}

extension TranscriptionServiceShutdownTests {
    func test_shutdown_during_upload_preserves_active_and_queued_audio() async throws {
        try await assertInterruptedQueueIsRecoverable(outcome: .empty)
    }

    func test_late_remote_error_does_not_mark_interrupted_recording_failed() async throws {
        try await assertInterruptedQueueIsRecoverable(outcome: .failure)
    }

    private func assertInterruptedQueueIsRecoverable(outcome: ShutdownEngineOutcome) async throws {
        let fixture = try ServiceShutdownFixture(stage: .transcribe, outcome: outcome)
        defer { fixture.cleanUp() }
        let first = try fixture.recording(title: "Active")
        let second = try fixture.recording(title: "Queued")
        let third = try fixture.recording(title: "After shutdown")
        fixture.service.shouldAutoDropShortEmpty = { _, _ in true }
        fixture.service.onTranscriptionCompleted = { _, _ in XCTFail("No late completion hook") }
        fixture.service.enqueue(first)
        fixture.service.enqueue(second)
        await fulfillment(of: [fixture.remote.gate.entered], timeout: 10)
        await fixture.service.shutdown()
        fixture.service.enqueue(third)
        await fixture.remote.gate.release()
        await fixture.service.waitForIdle(timeout: 10)
        XCTAssertNil(fixture.service.activeRecordingID, "Cancelled worker must finish")
        XCTAssertTrue(fixture.service.pendingIDs.isEmpty)
        let calls = await fixture.remote.transcribeCalls
        let swiftCancelled = await fixture.remote.observedSwiftCancellation
        let polledCancelled = await fixture.remote.observedPolledCancellation
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(swiftCancelled, "Worker cancellation must reach async-let children")
        XCTAssertTrue(polledCancelled, "The engine abort callback must also observe shutdown")
        XCTAssertNil(fixture.service.lastError)
        let reloaded = RecordingStore(rootDirectory: fixture.root)
        for original in [first, second, third] {
            let saved = try XCTUnwrap(reloaded.recordings.first { $0.id == original.id })
            let exists = FileManager.default.fileExists(atPath: reloaded.audioURL(for: saved).path)
            XCTAssertTrue(exists, "Shutdown must not auto-drop audio on a late empty/error result")
            XCTAssertEqual(MilaApp.recoveryAction(status: saved.status, wavExists: exists), .reenqueue)
        }
    }

    func test_shutdown_during_configure_does_not_start_remote_transcription() async throws {
        let fixture = try ServiceShutdownFixture(stage: .configure)
        defer { fixture.cleanUp() }
        let recording = try fixture.recording(title: "Configuring")
        let completed = expectation(description: "configure returned")
        // A one-shot call is independently scheduled, rather than owned by the queue worker.
        let call = Task {
            defer { completed.fulfill() }
            let result = await fixture.service.transcribeOnceSegments(
                samples: Array(repeating: 0.2, count: 16_000), language: "en", audioCtx: 0)
            XCTAssertTrue(result.isEmpty)
        }
        await fulfillment(of: [fixture.remote.gate.entered], timeout: 10)
        await fixture.service.shutdown()
        await fixture.remote.gate.release()
        await fulfillment(of: [completed], timeout: 10)
        call.cancel()
        let calls = await fixture.remote.transcribeCalls
        XCTAssertEqual(calls, 0)
        XCTAssertNil(fixture.service.lastError)
        XCTAssertEqual(fixture.store.recordings.first { $0.id == recording.id }?.status, .pending)
    }

    func test_shutdown_discards_late_one_shot_error_without_banner() async throws {
        let fixture = try ServiceShutdownFixture(stage: .transcribe, outcome: .failure)
        defer { fixture.cleanUp() }
        let completed = expectation(description: "one-shot returned")
        let call = Task {
            defer { completed.fulfill() }
            let result = await fixture.service.transcribeOnceSegments(
                samples: Array(repeating: 0.2, count: 16_000), language: "en", audioCtx: 0)
            XCTAssertTrue(result.isEmpty)
        }
        await fulfillment(of: [fixture.remote.gate.entered], timeout: 10)
        await fixture.service.shutdown()
        await fixture.remote.gate.release()
        await fulfillment(of: [completed], timeout: 10)
        call.cancel()
        XCTAssertNil(fixture.service.lastError)
    }

    func test_shutdown_during_local_load_does_not_start_transcription() async throws {
        let fixture = try ServiceShutdownFixture(stage: .load, local: true)
        defer { fixture.cleanUp() }
        let recording = try fixture.recording(title: "Loading")
        fixture.service.enqueue(recording)
        await fulfillment(of: [fixture.local.gate.entered], timeout: 10)
        await fixture.service.shutdown()
        await fixture.local.gate.release()
        await fixture.service.waitForIdle(timeout: 10)
        XCTAssertNil(fixture.service.activeRecordingID)
        let calls = await fixture.local.transcribeCalls
        XCTAssertEqual(calls, 0)
        XCTAssertNil(fixture.service.lastError)
        let saved = try XCTUnwrap(fixture.store.recordings.first { $0.id == recording.id })
        XCTAssertEqual(MilaApp.recoveryAction(status: saved.status, wavExists: true), .reenqueue)
    }

    func test_shutdown_waits_for_prewarm_before_local_teardown_and_is_idempotent() async throws {
        let fixture = try ServiceShutdownFixture(stage: .load, local: true)
        defer { fixture.cleanUp() }
        fixture.service.prewarm(language: "en")
        await fulfillment(of: [fixture.local.gate.entered], timeout: 10)
        let finished = expectation(description: "both shutdown callers returned")
        finished.expectedFulfillmentCount = 2
        let first = Task { await fixture.service.shutdown(); finished.fulfill() }
        let second = Task { await fixture.service.shutdown(); finished.fulfill() }
        await fulfillment(of: [fixture.remote.didShutdown], timeout: 10)
        let beforeRelease = await fixture.local.shutdownCalls
        XCTAssertEqual(beforeRelease, 0, "Do not tear down resources before the in-flight prewarm returns")
        await fixture.local.gate.release()
        await fulfillment(of: [finished], timeout: 10)
        first.cancel(); second.cancel()
        let localCount = await fixture.local.shutdownCalls
        let remoteCount = await fixture.remote.shutdownCalls
        XCTAssertEqual(localCount, 1)
        XCTAssertEqual(remoteCount, 1)
        fixture.service.prewarm(language: "en")
        let loads = await fixture.local.loadCalls
        XCTAssertEqual(loads, 1, "A terminal service must not schedule another prewarm")
    }
}

private enum ShutdownEngineStage: Equatable { case none, configure, load, transcribe }
private enum ShutdownEngineOutcome: Equatable { case empty, failure }

private actor ServiceShutdownGate {
    nonisolated let entered = XCTestExpectation(description: "engine reached barrier")
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor ShutdownControlledEngine: RemoteTranscribing {
    nonisolated let gate = ServiceShutdownGate()
    nonisolated let didShutdown = XCTestExpectation(description: "engine shutdown called")
    private let stage: ShutdownEngineStage
    private let outcome: ShutdownEngineOutcome
    private(set) var transcribeCalls = 0
    private(set) var loadCalls = 0
    private(set) var shutdownCalls = 0
    private(set) var observedSwiftCancellation = false
    private(set) var observedPolledCancellation = false
    init(stage: ShutdownEngineStage, outcome: ShutdownEngineOutcome = .empty) {
        self.stage = stage; self.outcome = outcome
    }
    func configure(_ config: RemoteTranscriptionConfig) async {
        if stage == .configure { await gate.wait() }
    }
    func loadIfNeeded(modelURL: URL, displayName: String) async throws {
        loadCalls += 1
        if stage == .load { await gate.wait() }
    }
    func shutdown() async { shutdownCalls += 1; didShutdown.fulfill() }
    func transcribe(samples: [Float], language: String, audioCtx: Int32?,
                    progress: (@Sendable (Float) -> Void)?,
                    isCancelled: (@Sendable () -> Bool)?) async throws -> [TranscriptSegment] {
        transcribeCalls += 1
        if stage == .transcribe { await gate.wait() }
        observedSwiftCancellation = Task.isCancelled
        observedPolledCancellation = isCancelled?() ?? false
        // Deliberately return a late empty result/error despite cancellation:
        // the service must defend its persistence and error-banner boundaries.
        if outcome == .failure { throw URLError(.networkConnectionLost) }
        return []
    }
}

@MainActor
private struct ServiceShutdownFixture {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let store: RecordingStore
    let remote: ShutdownControlledEngine
    let local: ShutdownControlledEngine
    let service: TranscriptionService
    init(stage: ShutdownEngineStage, outcome: ShutdownEngineOutcome = .empty, local useLocal: Bool = false) throws {
        root = TestSupport.makeTempRoot(label: "ServiceShutdown")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "ServiceShutdown.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = RecordingStore(rootDirectory: root)
        let manager = ModelManager(modelsDirectory: root.appendingPathComponent("Models"), defaults: defaults)
        try TestSupport.installFakeModel(into: manager)
        let settings = RemoteTranscriptionSettings(defaults: defaults, apiKeyKeychainKey: suiteName + ".unused-key")
        settings.endpoint = "http://localhost:8080/v1"
        settings.model = "whisper-1"
        settings.backend = useLocal ? .local : .remote
        remote = ShutdownControlledEngine(stage: useLocal ? .none : stage, outcome: outcome)
        local = ShutdownControlledEngine(stage: useLocal ? stage : .none, outcome: outcome)
        let diarization = DiarizationSettings(defaults: defaults)
        diarization.isEnabled = false
        service = TranscriptionService(store: store, modelManager: manager, diarizationSettings: diarization,
                                       remoteSettings: settings, engine: local, remoteEngine: remote)
    }
    func recording(title: String) throws -> Recording {
        let url = store.recordingsDirectory.appendingPathComponent("\(UUID()).wav")
        try TestSupport.writeSineWav(at: url)
        let row = Recording(title: title, source: .microphone, audioFileName: url.lastPathComponent,
                            status: .pending, language: "en")
        store.add(row)
        return row
    }
    func cleanUp() {
        Task { await remote.gate.release(); await local.gate.release() }
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}
