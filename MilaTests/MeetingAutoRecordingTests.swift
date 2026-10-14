import XCTest
import Combine
import TranscriptionCore
@testable import Mila

@MainActor
final class MeetingAutoRecordingTests: XCTestCase {
    private final class Recorder: MeetingRecordingActions {
        var meetingRecordingURL: URL?
        var canStartMeetingRecording = true
        let changes = PassthroughSubject<Void, Never>()
        var meetingRecordingChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
        var starts = 0
        var stops = 0
        var delayStart = false
        var continuation: CheckedContinuation<Void, Never>?
        func startMeetingRecording(isStillValid: @escaping () -> Bool) async -> URL? {
            starts += 1
            if delayStart { await withCheckedContinuation { continuation = $0 } }
            guard isStillValid(), meetingRecordingURL == nil else { return nil }
            meetingRecordingURL = URL(fileURLWithPath: "/tmp/meeting-\(UUID()).wav")
            changes.send()
            return meetingRecordingURL
        }
        func stopMeetingRecording(expectedURL: URL) async {
            guard meetingRecordingURL == expectedURL else { return }
            stops += 1
            meetingRecordingURL = nil
            changes.send()
        }
    }
    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: MeetingDetectionSettings!
    private var detector: MeetingDetector!
    private var recorder: Recorder!
    private var coordinator: MeetingPromptCoordinator!
    private var zoom: MeetingDetector.App { MeetingDetector.supportedApps[0] }
    private var other: MeetingDetector.App { MeetingDetector.supportedApps[1] }

    override func setUp() async throws {
        suite = "MeetingAutoRecordingTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        settings = MeetingDetectionSettings(defaults: defaults)
        detector = MeetingDetector(endConfirmationPolls: 1)
        recorder = Recorder()
        coordinator = MeetingPromptCoordinator(detector: detector, settings: settings,
            actions: recorder, presentsPanels: false, pollsDetector: false)
        coordinator.start()
    }
    override func tearDown() async throws {
        coordinator.stop()
        recorder.continuation?.resume()
        recorder.continuation = nil
        defaults.removePersistentDomain(forName: suite)
    }
    private func settle(until condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Expected asynchronous transition did not occur")
    }
    private func startAuto() async throws -> URL {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let prompt = try XCTUnwrap(coordinator.pending)
        XCTAssertTrue(prompt.automatic)
        coordinator.performPrompt(id: prompt.id)
        await settle { self.recorder.meetingRecordingURL != nil }
        return try XCTUnwrap(recorder.meetingRecordingURL)
    }

    func test_enable_auto_requires_a_fresh_countdown_before_capture() throws {
        detector.meetingStarted.send(zoom)
        let ask = try XCTUnwrap(coordinator.pending)
        coordinator.performPrompt(id: ask.id, enableAuto: true)
        let automatic = try XCTUnwrap(coordinator.pending)
        XCTAssertTrue(automatic.automatic)
        XCTAssertNotEqual(automatic.id, ask.id)
        XCTAssertEqual(settings.mode(forBundleID: zoom.bundleID), .auto)
        XCTAssertEqual(recorder.starts, 0, "Preference change must not immediately capture")
        coordinator.cancelPrompt(id: automatic.id)
        XCTAssertEqual(recorder.starts, 0)
    }
    func test_long_delivery_gap_cancels_even_when_interaction_was_paused() {
        var countdown = MeetingPromptCountdown()
        XCTAssertEqual(countdown.advance(by: 60, paused: true, automatic: true), .dismiss,
                       "Sleep or a long interruption cancels unattended automation")
    }

    func test_default_ask_and_off_never_schedule_automatic_recording() throws {
        detector.meetingStarted.send(zoom)
        XCTAssertFalse(try XCTUnwrap(coordinator.pending).automatic)
        coordinator.cancelPrompt(id: try XCTUnwrap(coordinator.pending).id)
        settings.setMode(.off, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(recorder.starts, 0)
    }
    func test_start_and_owned_stop_are_exactly_once() async throws {
        _ = try await startAuto()
        detector.meetingEnded.send(zoom)
        let prompt = try XCTUnwrap(coordinator.pending)
        XCTAssertEqual(prompt.kind, .stop)
        XCTAssertTrue(prompt.automatic)
        coordinator.performPrompt(id: prompt.id)
        coordinator.performPrompt(id: prompt.id)
        await settle { self.recorder.stops == 1 }
        XCTAssertEqual(recorder.starts, 1)
    }
    func test_cancelled_start_callback_cannot_record() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        coordinator.cancelPrompt(id: id)
        coordinator.performPrompt(id: id)
        XCTAssertEqual(recorder.starts, 0)
    }
    func test_end_rejoin_invalidates_old_start_callback() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let old = try XCTUnwrap(coordinator.pending)
        detector.meetingEnded.send(zoom)
        detector.meetingStarted.send(zoom)
        let current = try XCTUnwrap(coordinator.pending)
        XCTAssertNotEqual(old.meetingID, current.meetingID)
        coordinator.performPrompt(id: old.id)
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertEqual(coordinator.pending?.id, current.id)
    }
    func test_revoke_then_regrant_synchronously_does_not_revive_prompt() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        settings.setMode(.ask, forBundleID: zoom.bundleID)
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        coordinator.performPrompt(id: id)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(recorder.starts, 0)
    }
    func test_manual_start_while_prompt_visible_cannot_be_toggled_off() async throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        let manualURL = URL(fileURLWithPath: "/tmp/manual.wav")
        recorder.meetingRecordingURL = manualURL
        coordinator.performPrompt(id: id, enableAuto: true)
        XCTAssertEqual(recorder.meetingRecordingURL, manualURL)
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_manual_recording_gets_explicit_stop_even_in_auto_mode() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        recorder.meetingRecordingURL = URL(fileURLWithPath: "/tmp/manual.wav")
        detector.meetingStarted.send(zoom)
        detector.meetingEnded.send(zoom)
        XCTAssertFalse(try XCTUnwrap(coordinator.pending).automatic)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_keep_recording_cancels_automatic_stop() async throws {
        let url = try await startAuto()
        detector.meetingEnded.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        coordinator.cancelPrompt(id: id)
        coordinator.performPrompt(id: id)
        XCTAssertEqual(recorder.meetingRecordingURL, url)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_revoking_auto_keeps_active_recording_and_releases_ownership() async throws {
        let url = try await startAuto()
        settings.setMode(.off, forBundleID: zoom.bundleID)
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingEnded.send(zoom)
        XCTAssertEqual(recorder.meetingRecordingURL, url)
        XCTAssertFalse(try XCTUnwrap(coordinator.pending).automatic)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_global_disable_revokes_pending_stop_without_stopping() async throws {
        let url = try await startAuto()
        detector.meetingEnded.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        settings.enabled = false
        settings.enabled = true
        coordinator.performPrompt(id: id)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(recorder.meetingRecordingURL, url)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_rejoin_cancels_stop_and_does_not_take_ownership_of_previous_call() async throws {
        let url = try await startAuto()
        detector.meetingEnded.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        detector.meetingStarted.send(zoom)
        coordinator.performPrompt(id: id)
        XCTAssertNil(coordinator.pending)
        detector.meetingEnded.send(zoom)
        XCTAssertFalse(try XCTUnwrap(coordinator.pending).automatic)
        XCTAssertEqual(recorder.meetingRecordingURL, url)
    }
    func test_other_active_call_prevents_automatic_stop() async throws {
        _ = try await startAuto()
        detector.meetingStarted.send(other)
        detector.meetingEnded.send(zoom)
        XCTAssertFalse(try XCTUnwrap(coordinator.pending).automatic)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_other_app_cannot_claim_recording() async throws {
        _ = try await startAuto()
        settings.setMode(.auto, forBundleID: other.bundleID)
        detector.meetingStarted.send(other)
        detector.meetingEnded.send(other)
        XCTAssertFalse(try XCTUnwrap(coordinator.pending).automatic)
    }
    func test_replaced_recording_is_not_stopped_by_stale_callback() async throws {
        _ = try await startAuto()
        detector.meetingEnded.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        let replacement = URL(fileURLWithPath: "/tmp/replacement.wav")
        recorder.meetingRecordingURL = replacement
        coordinator.performPrompt(id: id)
        XCTAssertEqual(recorder.meetingRecordingURL, replacement)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_revocation_during_delayed_start_prevents_capture() async throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        recorder.delayStart = true
        detector.meetingStarted.send(zoom)
        coordinator.performPrompt(id: try XCTUnwrap(coordinator.pending).id)
        await settle { self.recorder.continuation != nil }
        settings.setMode(.off, forBundleID: zoom.bundleID)
        recorder.continuation?.resume()
        recorder.continuation = nil
        await Task.yield()
        XCTAssertNil(recorder.meetingRecordingURL)
        XCTAssertEqual(recorder.stops, 0)
    }
    func test_busy_start_falls_back_to_explicit_action() throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        recorder.canStartMeetingRecording = false
        detector.meetingStarted.send(zoom)
        let prompt = try XCTUnwrap(coordinator.pending)
        XCTAssertFalse(prompt.automatic)
        XCTAssertTrue(prompt.startUnavailable)
        coordinator.performPrompt(id: prompt.id)
        XCTAssertFalse(try XCTUnwrap(coordinator.pending).automatic)
        XCTAssertEqual(recorder.starts, 0)
    }
    func test_coordinator_stop_revokes_callbacks_and_start_is_idempotent() throws {
        coordinator.start()
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let id = try XCTUnwrap(coordinator.pending).id
        coordinator.stop()
        coordinator.performPrompt(id: id)
        detector.meetingStarted.send(zoom)
        XCTAssertNil(coordinator.pending)
        XCTAssertEqual(recorder.starts, 0)
    }
    func test_countdown_pause_cancel_and_exactly_once() {
        var countdown = MeetingPromptCountdown()
        for _ in 0..<9 { XCTAssertEqual(countdown.advance(by: 1, paused: false, automatic: true), .waiting) }
        for _ in 0..<15 { XCTAssertEqual(countdown.advance(by: 1, paused: true, automatic: true), .waiting) }
        XCTAssertEqual(countdown.elapsed, 9)
        XCTAssertEqual(countdown.advance(by: 1, paused: false, automatic: true), .primary)
        XCTAssertEqual(countdown.advance(by: 1, paused: false, automatic: true), .waiting)
        var cancelled = MeetingPromptCountdown()
        cancelled.cancel()
        XCTAssertEqual(cancelled.advance(by: 10, paused: false, automatic: true), .waiting)
    }
    func test_ask_timeout_dismisses_and_automatic_delivery_gap_cancels() {
        var ask = MeetingPromptCountdown()
        XCTAssertEqual(ask.advance(by: 10, paused: false, automatic: false), .dismiss)
        var auto = MeetingPromptCountdown()
        XCTAssertEqual(auto.advance(by: 60, paused: false, automatic: true), .dismiss)
        XCTAssertEqual(auto.advance(by: 1, paused: false, automatic: true), .waiting)
    }
    func test_modes_persist_and_off_cannot_leave_auto_authorized() {
        XCTAssertEqual(settings.mode(forBundleID: zoom.bundleID), .ask)
        for mode in [MeetingDetectionSettings.AppMode.auto, .off, .ask] {
            settings.setMode(mode, forBundleID: zoom.bundleID)
            let reloaded = MeetingDetectionSettings(defaults: defaults)
            XCTAssertEqual(reloaded.mode(forBundleID: zoom.bundleID), mode)
            XCTAssertEqual(reloaded.isAutoStart(forBundleID: zoom.bundleID), mode == .auto)
        }
    }
    func test_real_capture_rechecks_revocation_after_bringup_and_removes_partial_file() async throws {
        let session = RecordingSession()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cancelled-\(UUID()).wav")
        var valid = true
        session.system.bringUpOverride = { valid = false }
        do {
            try await session.start(source: .systemAudio, outputURL: url, isStillValid: { valid })
            XCTFail("Revoked start must not publish a recording")
        } catch is RecordingSession.StartCancelled {
            XCTAssertEqual(session.state, .idle)
            XCTAssertNil(session.fileURL)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }
    func test_real_capture_reserves_startup_before_first_await() async throws {
        let session = RecordingSession()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reserved-\(UUID()).wav")
        let otherURL = FileManager.default.temporaryDirectory.appendingPathComponent("other-\(UUID()).wav")
        var entered = false
        var release: CheckedContinuation<Void, Never>?
        session.system.bringUpOverride = {
            entered = true
            await withCheckedContinuation { release = $0 }
        }
        let first = Task { try await session.start(source: .systemAudio, outputURL: url) }
        await settle { entered }
        do {
            try await session.start(source: .systemAudio, outputURL: otherURL)
            XCTFail("Second startup must be rejected")
        } catch is RecordingSession.StartCancelled {}
        release?.resume()
        try await first.value
        XCTAssertEqual(session.fileURL, url)
        XCTAssertEqual(session.state, .recording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherURL.path))
        await session.cancelAll()
        try? FileManager.default.removeItem(at: url)
    }

}

/// Drives the coordinator through the REAL `QuickActionsController` +
/// `RecordingSession` (only the permission gate and the capture bring-up are
/// stubbed), so the automatic start/stop path is exercised on the seams the
/// merge touched — not the `Recorder` stub above.
@MainActor
final class MeetingAutoRecordingControllerTests: XCTestCase {
    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var service: TranscriptionService!
    private var session: RecordingSession!
    private var settings: MeetingDetectionSettings!
    private var detector: MeetingDetector!
    private var controller: QuickActionsController!
    private var coordinator: MeetingPromptCoordinator!
    private var defaults: UserDefaults!
    private var suite: String!
    private var zoom: MeetingDetector.App { MeetingDetector.supportedApps[0] }

    override func setUp() async throws {
        suite = "MeetingAutoRecordingControllerTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        settings = MeetingDetectionSettings(defaults: defaults)
        detector = MeetingDetector(endConfirmationPolls: 1)

        tempRoot = TestSupport.makeTempRoot(label: "MeetingAutoRecordingControllerTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        manager = TestSupport.isolatedModelManager(
            modelsDirectory: tempRoot.appendingPathComponent("Models"),
            label: "MeetingAutoRecordingControllerTests")
        try TestSupport.installFakeModel(into: manager)
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(
                defaults: .init(suiteName: "MeetingAutoRecordingControllerTests.diarization")!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: "MeetingAutoRecordingControllerTests"),
            engine: StubWhisperEngine())
        session = RecordingSession()
        controller = QuickActionsController(
            session: session,
            store: store,
            transcription: service,
            languageSettings: RecordingLanguageSettings(
                defaults: UserDefaults(suiteName: "MeetingAutoRecordingControllerTests.language")!),
            postRecording: PostRecordingCoordinator(
                store: store,
                transcription: service,
                llm: LLMSettings(defaults: UserDefaults(suiteName: "MeetingAutoRecordingControllerTests.llm")!)))
        controller.microphonePermissionOverride = { true }
        session.mic.bringUpOverride = { }
        session.system.bringUpOverride = { }

        coordinator = MeetingPromptCoordinator(detector: detector, settings: settings,
            actions: controller, presentsPanels: false, pollsDetector: false)
        coordinator.start()
    }

    override func tearDown() async throws {
        coordinator.stop()
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        defaults?.removePersistentDomain(forName: suite)
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

    func test_auto_mode_starts_and_stops_the_real_recording() async throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        detector.meetingStarted.send(zoom)
        let start = try XCTUnwrap(coordinator.pending)
        XCTAssertTrue(start.automatic)
        coordinator.performPrompt(id: start.id)

        let recording = await waitUntil { self.controller.isRecording }
        XCTAssertTrue(recording, "the automatic start must bring the real session up")
        XCTAssertEqual(session.source, .meeting)

        detector.meetingEnded.send(zoom)
        let stop = try XCTUnwrap(coordinator.pending)
        XCTAssertTrue(stop.automatic)
        coordinator.performPrompt(id: stop.id)
        let stopped = await waitUntil { !self.controller.isRecording }
        XCTAssertTrue(stopped)

        await controller.awaitFinalizeTails()
        await service.waitForIdle()
    }

    func test_revoking_auto_during_a_real_startup_prevents_the_recording() async throws {
        settings.setMode(.auto, forBundleID: zoom.bundleID)
        let gate = MeetingStartGate()
        session.mic.bringUpOverride = { await gate.wait() }
        session.mic.bringUpTimeout = 30

        detector.meetingStarted.send(zoom)
        let start = try XCTUnwrap(coordinator.pending)
        coordinator.performPrompt(id: start.id)
        let starting = await waitUntil { self.controller.isStartingRecording }
        XCTAssertTrue(starting)

        // Consent revoked while capture is still coming up.
        settings.setMode(.off, forBundleID: zoom.bundleID)
        await gate.open()
        let finished = await waitUntil { !self.controller.isStartingRecording }
        XCTAssertTrue(finished)

        XCTAssertFalse(controller.isRecording)
        XCTAssertNil(session.fileURL)
        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertTrue(store.recordings.isEmpty)
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
    }
}

/// Holds a fake bring-up open until the test opens it (file-scope so the
/// detached bring-up task can suspend on it).
private actor MeetingStartGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
