import XCTest
import TranscriptionCore
@testable import Mila

@MainActor
final class DictationControllerTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!
    private var manager: ModelManager!
    private var stub: StubWhisperEngine!
    private var service: TranscriptionService!
    private var hotkeys: HotkeySettings!
    private var defaultsSuite: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "DictationControllerTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
        UserDefaults().removePersistentDomain(forName: "DictationControllerTests")
        defaultsSuite = UserDefaults(suiteName: "DictationControllerTests")
        manager = ModelManager(modelsDirectory: tempRoot.appendingPathComponent("Models"), defaults: defaultsSuite)
        try TestSupport.installFakeModel(into: manager, model: .ivritLarge)
        try TestSupport.installFakeModel(into: manager, model: .openaiTurbo)
        stub = StubWhisperEngine()
        service = TranscriptionService(store: store, modelManager: manager, diarizationSettings: DiarizationSettings(defaults: .init(suiteName: "DictationControllerTests.diarization")!), remoteSettings: TestSupport.isolatedRemoteSettings(label: "DictationControllerTests"), engine: stub)
        hotkeys = HotkeySettings(defaults: defaultsSuite)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        defaultsSuite.removePersistentDomain(forName: "DictationControllerTests")
        try await super.tearDown()
    }

    /// A controller that leaves the host app's global hotkeys alone and
    /// tears its recorder down through `recorderTeardowns`.
    private func makeController(recorderTeardowns: RecorderTeardowns) -> (DictationController, LiveTranscriber) {
        let live = LiveTranscriber(transcription: service)
        let controller = DictationController(store: store,
                                             transcription: service,
                                             hotkeySettings: hotkeys,
                                             liveTranscriber: live,
                                             registersHotkeys: false,
                                             recorderTeardowns: recorderTeardowns)
        return (controller, live)
    }

    /// Polls `condition` for up to `timeout` seconds; returns its last value.
    private func eventually(_ condition: () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// `transcribeOnce` must route Hebrew audio to the ivrit.ai model and
    /// English audio to the OpenAI turbo, even when a different model is
    /// "selected" globally. This is the dictation-language plumbing the new
    /// per-language hotkeys depend on.
    func test_transcribe_once_uses_language_specific_model() async {
        manager.setSelected(.ivritLarge)
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: "hello world")
        ])
        let samples = [Float](repeating: 0.05, count: 16_000)

        _ = await service.transcribeOnce(samples: samples, language: "en")

        let loaded = await stub.loadedModel
        XCTAssertEqual(loaded?.lastPathComponent,
                       manager.url(for: .openaiTurbo).lastPathComponent,
                       "English dictation must load the OpenAI turbo model")
    }

    func test_transcribe_once_routes_hebrew_to_ivrit_model() async {
        manager.setSelected(.openaiTurbo)
        await stub.setDefaultCanned([
            TranscriptSegment(start: 0, end: 1, text: "שלום עולם")
        ])
        let samples = [Float](repeating: 0.05, count: 16_000)

        _ = await service.transcribeOnce(samples: samples, language: "he")

        let loaded = await stub.loadedModel
        XCTAssertEqual(loaded?.lastPathComponent,
                       manager.url(for: .ivritLarge).lastPathComponent,
                       "Hebrew dictation must load the ivrit.ai large-v3 model")
    }

    /// A hotkey press routes on the state, on whether a stop is still under
    /// way, and on whether a recorder teardown is still running. The state
    /// reads `.recording` while a stop tears the recorder down, so a
    /// double-tap used to run a second stop: a second final pass over empty
    /// audio that beeped and set `.idle` under the first one (#435 review).
    /// And a start while an earlier teardown is still stuck on the CoreAudio
    /// HAL would block another cooperative-pool thread on the same device.
    func test_a_press_while_the_recorder_tears_down_routes_safely() {
        let english = HotkeyAction.dictateEnglish
        func press(_ state: DictationController.State,
                   stopping: Bool = false,
                   shuttingDown: Bool = false) -> DictationController.PressOutcome {
            DictationController.outcome(ofPress: english, state: state,
                                        isStopping: stopping, isMicrophoneShuttingDown: shuttingDown)
        }
        XCTAssertEqual(press(.idle), .start)
        XCTAssertEqual(press(.recording(english)), .stop, "the first press of the same hotkey stops")
        XCTAssertEqual(press(.recording(english), stopping: true), .ignore,
                       "a press while that stop is still tearing down must not run a second stop")
        XCTAssertEqual(press(.idle, stopping: true), .refuseStart,
                       "no new dictation until a stop that a cancel overtook has finished")
        XCTAssertEqual(press(.idle, shuttingDown: true), .refuseStart,
                       "no new dictation while a recorder teardown is still running")
        XCTAssertEqual(DictationController.outcome(ofPress: .dictateHebrew, state: .idle,
                                                   isStopping: false, isMicrophoneShuttingDown: true),
                       .refuseStart, "whichever language's hotkey is pressed")
        XCTAssertEqual(press(.transcribing(english)), .ignore)
        XCTAssertEqual(press(.recording(.dictateHebrew)), .ignore,
                       "the other language's hotkey never stops a dictation")
    }

    /// A sleep, screen lock or quit during capture drops the dictation, as
    /// before. During the final pass it cannot stop whisper, but it must stop
    /// the paste: a synthesized Cmd-V into a locked screen types the
    /// transcript into the password field. After a sleep or lock the
    /// dictation is still saved to History, so the text is not lost.
    func test_a_cancel_during_the_final_pass_stops_only_the_paste() {
        let english = HotkeyAction.dictateEnglish
        XCTAssertEqual(DictationController.cancelEffect(for: .idle), .none)
        XCTAssertEqual(DictationController.cancelEffect(for: .recording(english)), .dropCapture)
        XCTAssertEqual(DictationController.cancelEffect(for: .transcribing(english)), .suppressPaste,
                       "a cancel during the final pass must not be a no-op")

        XCTAssertEqual(DictationController.finalPassOutcome(text: "hello", cancelledDuringPass: false), .paste)
        XCTAssertEqual(DictationController.finalPassOutcome(text: "", cancelledDuringPass: false), .beep)
        XCTAssertEqual(DictationController.finalPassOutcome(text: "hello", cancelledDuringPass: true),
                       .keepWithoutPasting, "no paste after a sleep, screen lock or quit")
        XCTAssertEqual(DictationController.finalPassOutcome(text: "", cancelledDuringPass: true),
                       .keepWithoutPasting)
    }

    /// Closing the lid sends both the screen-lock and the sleep guard to
    /// `cancelInFlight`, and a quit can follow while the first cancel is
    /// still waiting for the microphone. The quit then shuts the engine down,
    /// so nothing of the dictation may still be running by the time it
    /// returns: a live pass ticking into a torn-down engine aborts the
    /// process (#435 review: a quit that gave up joining the first cancel
    /// returned before that cancel had stopped the live transcriber). A
    /// cancel therefore does everything it does to the dictation before it
    /// waits, and whatever arrives second finds `.idle` and returns at once.
    func test_a_quit_during_a_slow_cancel_finds_the_live_transcriber_stopped() async {
        let teardown = HeldTeardown()
        let teardowns = RecorderTeardowns(deadline: 30, teardown: teardown.run)
        let (controller, live) = makeController(recorderTeardowns: teardowns)
        controller.beginRecordingForTesting(.dictateEnglish)
        XCTAssertTrue(live.isRunning, "setup: the live transcriber is running")

        let sleepCancel = Task { @MainActor in await controller.cancelInFlight() }
        guard await eventually({ teardown.isRunning }) else {
            teardown.finish()
            await sleepCancel.value
            return XCTFail("setup: the cancel never reached the recorder teardown")
        }
        XCTAssertFalse(live.isRunning,
                       "the cancel stops the live transcriber before it waits for the microphone")
        XCTAssertEqual(controller.state, .idle)

        let quitReturned = Flag()
        let quit = Task { @MainActor in
            await controller.cancelInFlight()
            quitReturned.isSet = true
        }
        let returnedInTime = await eventually({ quitReturned.isSet })
        XCTAssertTrue(returnedInTime, "the quit does not wait for the first cancel's stuck teardown")
        XCTAssertFalse(teardown.didFinish, "the first cancel is still waiting for the microphone")
        XCTAssertFalse(live.isRunning, "nothing of the dictation is running when the quit returns")
        XCTAssertEqual(controller.pressOutcome(for: .dictateEnglish), .refuseStart,
                       "no new dictation while the microphone is still shutting down")

        teardown.finish()
        await sleepCancel.value
        await quit.value
        XCTAssertFalse(teardowns.isShuttingDown)
        XCTAssertEqual(controller.pressOutcome(for: .dictateEnglish), .start,
                       "dictation starts again once the teardown has returned")
    }

    /// The recorder's teardown has no timeout of its own and runs
    /// `engine.stop()` on the shared cooperative pool, where it can block on
    /// the CoreAudio HAL. A stop or cancel waits for it at most its deadline
    /// and then carries on; a new dictation would block another pool thread
    /// on the same device, so starts stay refused until the teardown has
    /// actually returned, and work again as soon as it has.
    func test_a_start_is_refused_until_an_overdue_teardown_returns() async {
        let teardown = HeldTeardown()
        let teardowns = RecorderTeardowns(deadline: 0.1, teardown: teardown.run)
        let (controller, live) = makeController(recorderTeardowns: teardowns)
        controller.beginRecordingForTesting(.dictateHebrew)

        let started = Date()
        await controller.cancelInFlight()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "the cancel stops waiting at the deadline, not with the teardown")
        XCTAssertFalse(teardown.didFinish, "the teardown itself is still stuck")
        XCTAssertFalse(live.isRunning)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(teardowns.isShuttingDown)
        XCTAssertEqual(controller.pressOutcome(for: .dictateEnglish), .refuseStart,
                       "no start while the overdue teardown is still running")
        XCTAssertEqual(controller.pressOutcome(for: .dictateHebrew), .refuseStart)

        teardown.finish()
        let reenabled = await eventually({ !teardowns.isShuttingDown })
        XCTAssertTrue(reenabled, "the teardown's late return is counted")
        XCTAssertTrue(teardown.didFinish)
        XCTAssertEqual(controller.pressOutcome(for: .dictateEnglish), .start,
                       "starts work again once the teardown has returned")

        // A teardown that returns in time is reported as such, without
        // waiting for the deadline, and counted only while it runs.
        let quick = RecorderTeardowns(deadline: 30) {}
        let quickStart = Date()
        let pending = quick.begin()
        XCTAssertTrue(quick.isShuttingDown, "counted from begin(), before it has run")
        let inTime = await pending.wait()
        XCTAssertTrue(inTime)
        XCTAssertLessThan(Date().timeIntervalSince(quickStart), 5)
        XCTAssertFalse(quick.isShuttingDown)
        let again = await pending.wait()
        XCTAssertTrue(again, "a second look at a decided teardown returns at once")
        XCTAssertGreaterThan(DictationController.recorderTeardownDeadline, 0)
    }

    /// The TranscriptionService must forward `shutdown` to the engine. This
    /// is the fix path for the on-quit `ggml_abort` crash documented in the
    /// AppDelegate — without it, libc++ destroys the metal-device vector at
    /// `exit()` time before our context is freed.
    func test_shutdown_propagates_to_engine() async {
        await service.shutdown()
        let count = await stub.shutdownCount
        XCTAssertEqual(count, 1)
    }
}

/// A recorder teardown that does not return until the test says so.
@MainActor
private final class HeldTeardown {
    private(set) var isRunning = false
    private(set) var didFinish = false
    private var released = false
    private var release: CheckedContinuation<Void, Never>?

    func run() async {
        isRunning = true
        if !released {
            await withCheckedContinuation { release = $0 }
        }
        didFinish = true
    }

    /// Lets `run` return, now or (if it has not started yet) at once when it
    /// does, so a test that bails out early never leaves it parked.
    func finish() {
        released = true
        release?.resume()
        release = nil
    }
}

@MainActor
private final class Flag {
    var isSet = false
}
