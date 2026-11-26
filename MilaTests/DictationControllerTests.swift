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
    /// tears its recorder down through `stopRecorder`.
    private func makeController(stopRecorder: @escaping @MainActor () async -> Void,
                                teardownDeadline: TimeInterval = 30) -> (DictationController, LiveTranscriber) {
        let live = LiveTranscriber(transcription: service)
        let controller = DictationController(store: store,
                                             transcription: service,
                                             hotkeySettings: hotkeys,
                                             liveTranscriber: live,
                                             registersHotkeys: false,
                                             stopRecorder: stopRecorder,
                                             teardownDeadline: teardownDeadline)
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

    /// A hotkey press routes on the state AND on whether a stop or a cancel
    /// is still waiting for the recorder to tear down. The state reads
    /// `.recording` through a stop's wait, so a double-tap used to run a
    /// second stop: a second final pass over empty audio that beeped and set
    /// `.idle` under the first one (#435 review). A cancel sets `.idle`
    /// before its wait, and a start then would race the old engine's teardown
    /// on the same recorder.
    func test_a_second_press_while_the_recorder_tears_down_is_ignored() {
        let english = HotkeyAction.dictateEnglish
        func press(_ state: DictationController.State, tearingDown: Bool = false) -> DictationController.PressOutcome {
            DictationController.outcome(ofPress: english, state: state, isTearingDown: tearingDown)
        }
        XCTAssertEqual(press(.idle), .start)
        XCTAssertEqual(press(.recording(english)), .stop, "the first press of the same hotkey stops")
        XCTAssertEqual(press(.recording(english), tearingDown: true), .ignore,
                       "a press while a stop is still tearing down must not run a second stop")
        XCTAssertEqual(press(.idle, tearingDown: true), .ignore,
                       "no new dictation while a cancel waits for the recorder, though it set .idle")
        XCTAssertEqual(DictationController.outcome(ofPress: .dictateHebrew, state: .idle, isTearingDown: true),
                       .ignore, "whichever language's hotkey is pressed")
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
        let (controller, live) = makeController(stopRecorder: teardown.run)
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
        XCTAssertFalse(live.isRunning, "the live transcriber is stopped when the quit returns")
        XCTAssertEqual(controller.pressOutcome(for: .dictateEnglish), .ignore,
                       "no new dictation while the first cancel waits for the microphone")

        teardown.finish()
        await sleepCancel.value
        await quit.value
        XCTAssertEqual(controller.pressOutcome(for: .dictateEnglish), .start,
                       "presses work again once that wait is over")
    }

    /// A cancel whose recorder teardown never returns ignores presses only
    /// until the deadline; after it they start dictations again. Leaving
    /// `cancelsTearingDown` raised on that path would make one stuck
    /// teardown ignore every press until relaunch.
    func test_presses_work_again_once_a_cancel_stops_waiting_for_a_stuck_microphone() async {
        let teardown = HeldTeardown()
        let (controller, live) = makeController(stopRecorder: teardown.run, teardownDeadline: 2)
        controller.beginRecordingForTesting(.dictateHebrew)

        let cancelReturned = Flag()
        let cancel = Task { @MainActor in
            await controller.cancelInFlight()
            cancelReturned.isSet = true
        }
        guard await eventually({ teardown.isRunning }) else {
            teardown.finish()
            await cancel.value
            return XCTFail("setup: the cancel never reached the recorder teardown")
        }
        XCTAssertEqual(controller.pressOutcome(for: .dictateEnglish), .ignore,
                       "presses are ignored while the cancel waits")
        let returnedInTime = await eventually({ cancelReturned.isSet })
        XCTAssertTrue(returnedInTime, "the cancel stops waiting at the deadline")
        XCTAssertFalse(teardown.didFinish, "the teardown itself is still stuck")
        XCTAssertFalse(live.isRunning)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.pressOutcome(for: .dictateEnglish), .start,
                       "presses start dictations again after the deadline")
        XCTAssertEqual(controller.pressOutcome(for: .dictateHebrew), .start)

        teardown.finish()
        await cancel.value
    }

    /// Quit calls `beginShutdown()` before anything else, and from then on no
    /// press starts a dictation: not even once the quit's own cancel has set
    /// `.idle` and the microphone has shut down, which is when one used to
    /// (#435 review). That dictation came after the quit's cancel, so its
    /// mic stayed open until exit.
    func test_a_press_after_quit_begins_does_not_start_a_dictation() async {
        let (controller, live) = makeController(stopRecorder: {})
        controller.beginRecordingForTesting(.dictateEnglish)

        controller.beginShutdown()
        XCTAssertEqual(controller.pressOutcome(for: .dictateEnglish), .quitting,
                       "not even the hotkey that would stop the recording")
        await controller.cancelInFlight()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(live.isRunning, "the quit's cancel still drops the dictation")
        XCTAssertEqual(controller.pressOutcome(for: .dictateEnglish), .quitting)
        XCTAssertEqual(controller.pressOutcome(for: .dictateHebrew), .quitting)

        // Only press once the routing is known to do nothing: a regression
        // to `.start` would ask for the real microphone here.
        guard controller.pressOutcome(for: .dictateHebrew) == .quitting else { return }
        await controller.toggle(action: .dictateHebrew)
        XCTAssertEqual(controller.state, .idle, "the press started nothing")
        XCTAssertFalse(live.isRunning)
    }

    /// The recorder's teardown has no timeout of its own and can block on
    /// the CoreAudio HAL. A stop or cancel waits for it at most
    /// `recorderTeardownDeadline`, then carries on, so a teardown that never
    /// returns cannot leave every later press ignored until relaunch. Its
    /// completion after the deadline must change nothing: in particular it
    /// must not resume the wait a second time, which would trap.
    func test_a_teardown_that_overruns_the_deadline_is_left_behind() async {
        let teardown = HeldTeardown()
        let lateReturn = Flag()
        let started = Date()
        let inTime = await DictationController.waitAtMost(0.1, for: {
            await teardown.run()
        }, onLateReturn: { lateReturn.isSet = true })
        XCTAssertFalse(inTime, "the wait must give up at the deadline")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "the wait must end at the deadline, not with the teardown")
        XCTAssertTrue(teardown.isRunning, "the teardown itself keeps running")

        XCTAssertFalse(lateReturn.isSet)
        teardown.finish()
        let reported = await eventually({ lateReturn.isSet })
        XCTAssertTrue(reported, "the late completion is reported, and resumes nothing")
        XCTAssertTrue(teardown.didFinish)

        let quick = Date()
        let onTime = Flag()
        let fast = await DictationController.waitAtMost(30, for: {}, onLateReturn: { onTime.isSet = true })
        XCTAssertTrue(fast, "a teardown that returns in time is reported as such")
        XCTAssertFalse(onTime.isSet, "a return in time is not a late one")
        XCTAssertLessThan(Date().timeIntervalSince(quick), 5,
                          "a teardown that returns at once must not wait for the deadline")
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
