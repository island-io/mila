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

        let reachedStarting = await waitUntil { controller.activeJob == .starting(.microphone) }
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
        XCTAssertEqual(controller.activeJob, .starting(.microphone),
                       "a click during the bring-up must be dropped, not toggle the state")

        await gate.open()
        await start.value

        XCTAssertEqual(controller.activeJob, .recording(withSystemAudio: false))
        XCTAssertTrue(controller.isRecording)
        XCTAssertFalse(controller.isStartingRecording)
        XCTAssertEqual(session.state, .recording)
        XCTAssertTrue(session.mic.isRunning)
        XCTAssertEqual(published.jobs, [.starting(.microphone), .recording(withSystemAudio: false)],
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
            throw MicrophoneError.bringUpTimedOut(device: "AirPods 4", timeout: 12)
        }
        let published = PublishedJobs(controller)

        let start = Task { await controller.toggleRecord(microphone: true, appAudio: false) }
        let reachedStarting = await waitUntil { controller.activeJob == .starting(.microphone) }
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
        XCTAssertEqual(published.jobs, [.starting(.microphone), .none])

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
        XCTAssertEqual(published.jobs, [.starting(.microphone), .none])
    }

    // MARK: - Nothing to stop yet

    /// `stopRecording` is unguarded by the UI in this window only because every
    /// stop affordance is hidden or disabled; the programmatic callers still
    /// reach it. Letting it through would save a zero-length "recording",
    /// present the rename sheet, and stamp `.none` over `.starting` seconds
    /// before the bring-up completes.
    func test_stop_during_starting_is_ignored_rather_than_saving_a_phantom_recording() async throws {
        let gate = BringUpGate()
        session.mic.bringUpOverride = { await gate.wait() }

        let start = Task { await controller.toggleRecord(microphone: true, appAudio: false) }
        let reachedStarting = await waitUntil { controller.activeJob == .starting(.microphone) }
        XCTAssertTrue(reachedStarting)

        await controller.stopRecording()
        XCTAssertEqual(controller.activeJob, .starting(.microphone),
                       "a stop before capture is up has nothing to stop and must leave the start alone")
        XCTAssertTrue(store.recordings.isEmpty,
                      "a stop that arrives before capture is up must not mint a recording")
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

    // MARK: - Imports do not own the record job

    /// ⌘O (or a drop onto the More page) is legitimately concurrent with a
    /// recording, and `activeJob` is what backs `isRecording`. `transcribeFile`
    /// used to claim it unconditionally and release it to `.none` when the
    /// import finished. During `.starting` that replaced the start in flight,
    /// whose success then wrote `.recording` back — and the import finishing
    /// stamped `.none` over a live recording: the UI read idle with the mic
    /// hot, and the next Record click ran a second bring-up. (Cursor Bugbot on
    /// #294; `QuickActionsControllerTests` pins the same clobber against an
    /// already-running recording.)
    func test_a_file_import_during_starting_does_not_steal_the_job() async throws {
        let gate = BringUpGate()
        session.mic.bringUpOverride = { await gate.wait() }

        let start = Task { await controller.toggleRecord(microphone: true, appAudio: false) }
        let reachedStarting = await waitUntil { controller.activeJob == .starting(.microphone) }
        XCTAssertTrue(reachedStarting)

        // ⌘O arrives while capture is still coming up.
        let imported = tempRoot.appendingPathComponent("import-during-start.wav")
        try TestSupport.writeStereo48kSineWav(at: imported, durationSeconds: 0.4)
        await controller.transcribeFile(imported)
        XCTAssertEqual(controller.activeJob, .starting(.microphone),
                       "an import must neither take activeJob away from a start in flight nor release it to .none afterwards")
        XCTAssertNotNil(store.recordings.first { $0.title == "import-during-start" },
                        "the import itself still goes through")

        await gate.open()
        await start.value
        XCTAssertEqual(controller.activeJob, .recording(withSystemAudio: false))
        XCTAssertTrue(controller.isRecording)

        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
        XCTAssertEqual(controller.activeJob, .none)
    }

    // MARK: - Sleep / lock during the bring-up (#321)

    /// The sleep and lock guards used to act only on `isRecording`, which
    /// excludes `.starting`, so a lid close inside the bring-up window let
    /// capture come up after the wake and run unattended. The request must
    /// hold the job at `.starting` while the bring-up is still out (a second
    /// start would run a second bring-up on the same recorder, #293), and
    /// when the bring-up returns, take capture back down, save nothing, leave
    /// no WAV behind, tell the user, and leave the button usable.
    func test_sleep_during_starting_abandons_the_start() async throws {
        try await assertAbandonsTheStart(reason: .systemSleep, cause: "sleep")
    }

    /// Same shape for a deliberate Lock Screen.
    func test_screen_lock_during_starting_abandons_the_start() async throws {
        try await assertAbandonsTheStart(reason: .screenLock, cause: "locked")
    }

    /// A bring-up that fails on its own after the start was abandoned reports
    /// the abandonment — what the user did — not an error from a start they
    /// were not there to see.
    func test_an_abandoned_start_whose_bring_up_fails_reports_the_abandonment() async throws {
        let gate = BringUpGate()
        session.mic.bringUpOverride = {
            await gate.wait()
            throw MicrophoneError.bringUpTimedOut(device: "AirPods 4", timeout: 12)
        }
        let published = PublishedJobs(controller)

        let start = Task { await controller.toggleRecord(microphone: true, appAudio: false) }
        let reachedStarting = await waitUntil { controller.activeJob == .starting(.microphone) }
        XCTAssertTrue(reachedStarting)

        controller.abandonStartingRecording(reason: .systemSleep)
        await gate.open()
        await start.value

        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(service.lastError?.contains("did not start") ?? false,
                      "expected the abandonment message, got \(String(describing: service.lastError))")
        XCTAssertEqual(published.jobs, [.starting(.microphone), .none])
    }

    /// Meeting mode brings the microphone up first and system audio second.
    /// A cancel that arrives during the microphone's bring-up must stop the
    /// whole start there: neither leg may open capture (#328).
    func test_an_abandoned_meeting_start_opens_neither_capture_leg() async throws {
        let gate = BringUpGate()
        session.mic.bringUpOverride = { await gate.wait() }
        let systemBringUps = BringUpCounter()
        session.system.bringUpOverride = { await systemBringUps.increment() }

        let start = Task { await controller.toggleRecord(withSystemAudio: true) }
        let reachedStarting = await waitUntil { controller.activeJob == .starting(.meeting) }
        XCTAssertTrue(reachedStarting)

        controller.abandonStartingRecording(reason: .screenLock)
        await gate.open()
        await start.value

        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.mic.captureStartCount, 0, "the microphone must never have started")
        let systemCount = await systemBringUps.count
        XCTAssertEqual(systemCount, 0, "the system-audio leg must not be brought up for an abandoned start")
        XCTAssertFalse(session.system.isRunning)
        XCTAssertTrue(service.lastError?.contains("did not start") ?? false,
                      "expected the abandonment message, got \(String(describing: service.lastError))")
    }

    /// The more common meeting-mode timing: the microphone is already up and
    /// the lock arrives while system audio is still being brought up. The
    /// system leg must stop short of starting its stream, and the microphone
    /// that did come up must be taken down by the partial-bring-up teardown.
    func test_a_meeting_start_abandoned_during_the_system_leg_never_opens_it() async throws {
        session.mic.bringUpOverride = { }
        let gate = BringUpGate()
        session.system.bringUpOverride = { await gate.wait() }
        var systemRunningValues: [Bool] = []
        let systemRunning = session.system.$isRunning.sink { systemRunningValues.append($0) }
        defer { systemRunning.cancel() }

        let start = Task { await controller.toggleRecord(withSystemAudio: true) }
        let micUp = await waitUntil { self.session.mic.isRunning }
        XCTAssertTrue(micUp, "the mic leg comes up first, then the system leg waits on the gate")
        XCTAssertEqual(controller.activeJob, .starting(.meeting))

        controller.abandonStartingRecording(reason: .screenLock)
        await gate.open()
        await start.value

        XCTAssertEqual(controller.activeJob, .none)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.mic.captureStartCount, 1)
        XCTAssertFalse(session.mic.isRunning, "the mic that came up must be taken down again")
        XCTAssertFalse(systemRunningValues.contains(true),
                       "the system-audio stream must never have started, saw \(systemRunningValues)")
        XCTAssertTrue(service.lastError?.contains("did not start") ?? false,
                      "expected the abandonment message, got \(String(describing: service.lastError))")
    }

    /// Sleep can arrive while the microphone permission prompt is still up —
    /// before the bring-up has even begun. The start must stop there rather
    /// than go on to bring capture up.
    func test_sleep_during_the_permission_prompt_never_reaches_the_bring_up() async throws {
        let bringUps = BringUpCounter()
        session.mic.bringUpOverride = { await bringUps.increment() }
        controller.microphonePermissionOverride = { [unowned self] in
            MainActor.assumeIsolated {
                self.controller.abandonStartingRecording(reason: .systemSleep)
            }
            return true
        }

        await controller.toggleRecord(microphone: true, appAudio: false)

        XCTAssertEqual(controller.activeJob, .none)
        let bringUpCount = await bringUps.count
        XCTAssertEqual(bringUpCount, 0, "an abandoned start must not go on to bring capture up")
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(service.lastError?.contains("did not start") ?? false)
    }

    /// Outside `.starting` the request is a no-op: an idle controller has
    /// nothing to abandon — and a stale request must not reach the NEXT
    /// start — and an active recording is the guards' `stopRecording` path,
    /// which this must not pre-empt.
    func test_abandon_outside_starting_is_a_no_op() async throws {
        controller.abandonStartingRecording(reason: .systemSleep)
        session.mic.bringUpOverride = { }
        await controller.toggleRecord(microphone: true, appAudio: false)
        XCTAssertEqual(controller.activeJob, .recording(withSystemAudio: false),
                       "a request made while idle must not abandon a later start")
        XCTAssertNil(service.lastError)

        controller.abandonStartingRecording(reason: .screenLock)
        XCTAssertEqual(controller.activeJob, .recording(withSystemAudio: false))
        XCTAssertEqual(session.state, .recording,
                       "an active recording is stopped by the guards' existing path, not by this")

        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
        XCTAssertEqual(controller.activeJob, .none)
    }

    // MARK: - What "Starting…" is waiting on (#321)

    /// ⌘N / New Voice Memo and the meeting prompt's Record both bring the
    /// microphone up whatever the Home Microphone toggle says, so the
    /// caption has to come from the source the controller is starting. ⌘N
    /// is a mic-only start; the meeting prompt is mic + system audio.
    func test_starting_carries_the_source_being_brought_up() async throws {
        let gate = BringUpGate()
        session.mic.bringUpOverride = {
            await gate.wait()
            // End both starts before the system-audio leg, which CI cannot run.
            throw MicrophoneError.bringUpTimedOut(device: "AirPods 4", timeout: 12)
        }

        let voiceMemo = Task { await controller.toggleVoiceMemo() }
        let memoStarting = await waitUntil { controller.startingSource == .microphone }
        XCTAssertTrue(memoStarting, "⌘N starts a microphone capture")
        await gate.open()
        await voiceMemo.value
        XCTAssertNil(controller.startingSource)

        let gate2 = BringUpGate()
        session.mic.bringUpOverride = {
            await gate2.wait()
            throw MicrophoneError.bringUpTimedOut(device: "AirPods 4", timeout: 12)
        }
        let meeting = Task { await controller.toggleRecord(withSystemAudio: true) }
        let meetingStarting = await waitUntil { controller.startingSource == .meeting }
        XCTAssertTrue(meetingStarting, "the meeting prompt's Record starts mic + system audio")
        XCTAssertTrue(controller.isStartingRecording)
        await gate2.open()
        await meeting.value
        XCTAssertNil(controller.startingSource)
        XCTAssertEqual(controller.activeJob, .none)
    }

    private func assertAbandonsTheStart(reason: QuickActionsController.StartAbandonReason,
                                        cause: String,
                                        file: StaticString = #filePath,
                                        line: UInt = #line) async throws {
        let gate = BringUpGate()
        session.mic.bringUpOverride = { await gate.wait() }
        let published = PublishedJobs(controller)

        let start = Task { await controller.toggleRecord(microphone: true, appAudio: false) }
        let reachedStarting = await waitUntil { controller.activeJob == .starting(.microphone) }
        XCTAssertTrue(reachedStarting, file: file, line: line)

        controller.abandonStartingRecording(reason: reason)
        XCTAssertEqual(controller.activeJob, .starting(.microphone),
                       "the job must stay claimed until the bring-up in flight returns",
                       file: file, line: line)
        // A click in the meantime is still dropped, not a second bring-up.
        await controller.toggleRecord(microphone: true, appAudio: false)
        XCTAssertEqual(controller.activeJob, .starting(.microphone), file: file, line: line)

        await gate.open()
        await start.value

        XCTAssertEqual(controller.activeJob, .none, "an abandoned start must not become a recording",
                       file: file, line: line)
        XCTAssertFalse(controller.isRecording, file: file, line: line)
        XCTAssertEqual(session.state, .idle, file: file, line: line)
        XCTAssertFalse(session.mic.isRunning, "the capture that came up must be taken down again",
                       file: file, line: line)
        // The cancel arrived while the bring-up was still out, so it must
        // have stopped short of opening capture — not let the microphone (and
        // its orange indicator) come on for the cleanup to take down (#328).
        XCTAssertEqual(session.mic.captureStartCount, 0,
                       "a start abandoned during the bring-up must never start the engine",
                       file: file, line: line)
        XCTAssertTrue(store.recordings.isEmpty, "nothing was recorded, so nothing may be saved",
                      file: file, line: line)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            at: store.recordingsDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "wav" } ?? []
        XCTAssertEqual(leftovers, [], "the never-used WAV must not survive to be 'recovered' on next launch",
                       file: file, line: line)
        let message = service.lastError ?? ""
        XCTAssertTrue(message.contains("did not start") && message.contains(cause),
                      "the user must be told why nothing is recording, got \(message)",
                      file: file, line: line)
        XCTAssertEqual(published.jobs, [.starting(.microphone), .none], file: file, line: line)

        // The abandonment must not wedge the button.
        service.lastError = nil
        session.mic.bringUpOverride = { }
        await controller.toggleRecord(microphone: true, appAudio: false)
        XCTAssertEqual(controller.activeJob, .recording(withSystemAudio: false), file: file, line: line)
        XCTAssertNil(service.lastError, "a fresh start must not inherit the abandoned one's request",
                     file: file, line: line)
        XCTAssertEqual(session.mic.captureStartCount, 1,
                       "a fresh start must not inherit the abandoned one's cancellation",
                       file: file, line: line)

        await controller.stopRecording()
        await controller.awaitFinalizeTails()
        await service.waitForIdle()
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

/// Counts how many times the fake bring-up ran. An actor for the same reason
/// as `BringUpGate`: the override runs off the main actor.
private actor BringUpCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
