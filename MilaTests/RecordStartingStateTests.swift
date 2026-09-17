import XCTest
import Combine
@testable import Mila

/// Pins the `.starting` job state a Record click publishes while capture is
/// still being brought up (island-io/mila#293).
///
/// `QuickActionsController.startRecording` used to flip `activeJob` only
/// AFTER `session.start` returned, and on a Bluetooth input that return can
/// take ~6 s (two ~3 s AVFoundation format waits, #291). For the whole window
/// the Home Record button looked exactly as it did before the click — and a
/// second click ran a second bring-up, because `RecordingSession.state` and
/// `MicrophoneRecorder.isRunning` both stay in their idle values until the
/// first one finishes.
///
/// These tests drive the REAL `RecordingSession` / `MicrophoneRecorder` —
/// not the `startFakeRecordingForTesting` seam, which skips the bring-up
/// entirely — with `MicrophoneRecorder.bringUpOverride` parked on a gate the
/// test opens. That makes the window deterministic: the assertions inside it
/// cannot race a fast machine, and the ones after it cannot race a slow one.
@MainActor
final class RecordStartingStateTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var service: TranscriptionService!
    private var session: RecordingSession!
    private var controller: QuickActionsController!
    private var languageDefaults: UserDefaults!
    private let languageSuite = "RecordStartingStateTests.language"
    private let llmSuite = "RecordStartingStateTests.llm"

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "RecordStartingStateTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        store = RecordingStore(rootDirectory: tempRoot)
        // `session.start` opens the WAV with `AVAudioFile(forWriting:)`, which
        // needs the directory to exist — the store creates it on init, but
        // make the precondition explicit rather than inherited.
        try FileManager.default.createDirectory(at: store.recordingsDirectory,
                                                withIntermediateDirectories: true)
        manager = TestSupport.isolatedModelManager(
            modelsDirectory: tempRoot.appendingPathComponent("Models"),
            label: "RecordStartingStateTests")
        try TestSupport.installFakeModel(into: manager)
        service = TranscriptionService(
            store: store,
            modelManager: manager,
            diarizationSettings: DiarizationSettings(
                defaults: .init(suiteName: "RecordStartingStateTests.diarization")!),
            remoteSettings: TestSupport.isolatedRemoteSettings(label: "RecordStartingStateTests"),
            engine: StubWhisperEngine())

        session = RecordingSession()
        // The seam installs no tap, so the frame count never grows and the
        // stall watchdog would otherwise start "repairing" capture mid-test.
        session.mic.captureStallTimeout = 600
        // The bring-up is held on a gate the test opens; a loaded runner must
        // not be able to lose that race to the real timeout.
        session.mic.bringUpTimeout = 30

        UserDefaults().removePersistentDomain(forName: languageSuite)
        UserDefaults().removePersistentDomain(forName: llmSuite)
        languageDefaults = UserDefaults(suiteName: languageSuite)
        controller = QuickActionsController(
            session: session,
            store: store,
            transcription: service,
            languageSettings: RecordingLanguageSettings(defaults: languageDefaults),
            postRecording: PostRecordingCoordinator(
                store: store,
                transcription: service,
                llm: LLMSettings(defaults: UserDefaults(suiteName: llmSuite)!)))
        // The hosted test bundle holds no microphone grant on CI, and
        // `AVCaptureDevice.requestAccess` there either denies or never calls
        // back. The permission gate is not what these tests are about.
        controller.microphonePermissionOverride = { true }
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        languageDefaults?.removePersistentDomain(forName: languageSuite)
        UserDefaults().removePersistentDomain(forName: llmSuite)
        try await super.tearDown()
    }

    // MARK: - Success path

    /// The click must be visible BEFORE the bring-up finishes, and the
    /// interim state must be replaced — not merely joined — by `.recording`.
    /// Also the double-click case: both Home entry points drop a second
    /// click while the first is still starting, so exactly one bring-up runs.
    func test_a_slow_bring_up_publishes_starting_then_recording() async throws {
        let gate = BringUpGate()
        session.mic.bringUpOverride = { await gate.wait() }
        let published = PublishedJobs(controller)

        let start = Task { await controller.toggleRecord(microphone: true, appAudio: false) }

        let reachedStarting = await waitUntil { controller.activeJob == .starting }
        XCTAssertTrue(reachedStarting,
                      "`.starting` must be published before the first await of the start path — "
                      + "it is the only thing the user sees for the length of the bring-up")
        XCTAssertTrue(controller.isStartingRecording)
        XCTAssertFalse(controller.isRecording,
                       "there is no session to stop yet; `.starting` must not read as recording")
        XCTAssertEqual(session.state, .idle,
                       "sanity: the session itself has not started — this is the window the indicator exists for")
        XCTAssertFalse(session.mic.isRunning)

        // A second click, through both Home entry points, while the first is
        // still bringing capture up. Neither may stop (nothing to stop) nor
        // start (a second bring-up on the same recorder).
        await controller.toggleRecord(microphone: true, appAudio: false)
        await controller.toggleRecord(withSystemAudio: false)
        XCTAssertEqual(controller.activeJob, .starting,
                       "a click during the bring-up must be dropped, not toggle the state")

        await gate.open()
        await start.value

        XCTAssertEqual(controller.activeJob, .recording(withSystemAudio: false))
        XCTAssertTrue(controller.isRecording)
        XCTAssertFalse(controller.isStartingRecording)
        XCTAssertEqual(session.state, .recording)
        XCTAssertTrue(session.mic.isRunning)
        XCTAssertEqual(published.jobs, [.starting, .recording(withSystemAudio: false)],
                       "one flip in, one flip out — the dropped clicks must not have published anything")

        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
        XCTAssertEqual(controller.activeJob, .none)
    }

    // MARK: - Failure path

    /// A bring-up that throws must take `.starting` back to `.none` — a
    /// button stuck on "Starting…" after the error banner would be the bug
    /// this feature exists to fix, in a new shape — and the next click must
    /// go through.
    func test_a_failed_bring_up_clears_starting_and_leaves_the_button_usable() async throws {
        let gate = BringUpGate()
        session.mic.bringUpOverride = {
            await gate.wait()
            // The error #291 produced: the engine outlived `bringUpTimeout`.
            throw MicrophoneError.bringUpTimedOut
        }
        let published = PublishedJobs(controller)

        let start = Task { await controller.toggleRecord(microphone: true, appAudio: false) }
        let reachedStarting = await waitUntil { controller.activeJob == .starting }
        XCTAssertTrue(reachedStarting)

        await gate.open()
        await start.value

        XCTAssertEqual(controller.activeJob, .none, "a failed start must clear the interim state")
        XCTAssertFalse(controller.isStartingRecording)
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.mic.isRunning, "the session tore its partial bring-up down")
        XCTAssertNotNil(service.lastError, "the failure is reported to the user, not swallowed")
        XCTAssertTrue(store.recordings.isEmpty, "nothing was captured, so nothing may be saved")
        XCTAssertEqual(published.jobs, [.starting, .none])

        // The failure must not wedge the button: the next click starts for real.
        session.mic.bringUpOverride = { }
        await controller.toggleRecord(microphone: true, appAudio: false)
        XCTAssertEqual(controller.activeJob, .recording(withSystemAudio: false))

        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
    }

    /// The denied-permission exit is the other pre-`session.start` failure;
    /// it must undo `.starting` too. Drives the seam's `false` branch, which
    /// is why the seam reports the denial the way the real check does.
    func test_a_denied_microphone_permission_clears_starting() async throws {
        controller.microphonePermissionOverride = { false }
        let published = PublishedJobs(controller)

        await controller.toggleRecord(microphone: true, appAudio: false)

        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertTrue(controller.microphonePermissionMissing,
                      "the denial must still surface the Privacy Settings alert")
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(session.mic.isRunning, "a denied permission must never reach the bring-up")
        XCTAssertEqual(published.jobs, [.starting, .none])
    }

    // MARK: - Nothing to stop yet

    /// `stopRecording` is unguarded by the UI in this window only because every
    /// stop affordance is hidden or disabled; the programmatic callers still
    /// reach it. Letting it through would save a zero-length "recording",
    /// present the rename sheet, and stamp `.none` over `.starting` seconds
    /// before the bring-up lands.
    func test_stop_during_starting_is_ignored_rather_than_saving_a_phantom_recording() async throws {
        let gate = BringUpGate()
        session.mic.bringUpOverride = { await gate.wait() }

        let start = Task { await controller.toggleRecord(microphone: true, appAudio: false) }
        let reachedStarting = await waitUntil { controller.activeJob == .starting }
        XCTAssertTrue(reachedStarting)

        await controller.stopRecording()
        XCTAssertEqual(controller.activeJob, .starting,
                       "a stop before capture is up has nothing to stop and must leave the start alone")
        XCTAssertTrue(store.recordings.isEmpty,
                      "a stop that lands before capture is up must not mint a recording")
        XCTAssertFalse(controller.isFinalizingRecording)

        await gate.open()
        await start.value
        XCTAssertEqual(controller.activeJob, .recording(withSystemAudio: false),
                       "the ignored stop must not have derailed the start")

        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
        XCTAssertEqual(controller.activeJob, .none)
    }

    // MARK: - Helpers

    /// Poll `condition` on the main actor until it holds or `timeout` passes.
    /// Returns the final reading, so a failure reports the state rather than
    /// just "timed out".
    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// Records every `activeJob` transition after subscription. `$activeJob`
    /// replays the current value on subscribe; that one is dropped so `jobs`
    /// holds only what the click under test caused.
    @MainActor
    private final class PublishedJobs {
        private(set) var jobs: [QuickActionsController.ActiveJob] = []
        private var cancellable: AnyCancellable?

        init(_ controller: QuickActionsController) {
            cancellable = controller.$activeJob
                .dropFirst()
                .sink { [weak self] job in self?.jobs.append(job) }
        }
    }
}

/// Holds the fake microphone bring-up open until the test lets it through.
/// The override runs on the detached task `MicrophoneRecorder.withTimeout`
/// spawns, so the gate is an actor rather than main-actor state.
private actor BringUpGate {
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
