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
    /// is still tearing the recorder down. The state reads `.recording`
    /// through that wait, so a double-tap used to run a second stop: a second
    /// final pass over empty audio that beeped and set `.idle` under the
    /// first one (#435 review). During a cancel's teardown a press would have
    /// transcribed, and pasted, the capture the cancel is dropping.
    func test_a_second_press_while_the_recorder_tears_down_is_ignored() {
        let english = HotkeyAction.dictateEnglish
        func press(_ state: DictationController.State, tearingDown: Bool = false) -> DictationController.PressOutcome {
            DictationController.outcome(ofPress: english, state: state, isTearingDown: tearingDown)
        }
        XCTAssertEqual(press(.idle), .start)
        XCTAssertEqual(press(.recording(english)), .stop, "the first press of the same hotkey stops")
        XCTAssertEqual(press(.recording(english), tearingDown: true), .ignore,
                       "a press while a stop or cancel is still tearing down must not run a stop")
        XCTAssertEqual(press(.idle, tearingDown: true), .ignore,
                       "no new dictation while the recorder is still tearing down, even after a cancel set .idle")
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
    /// `cancelInFlight`. The second cancel's `stop()` returns at once, so
    /// when it ran its own teardown it cleared the cancelling flag and set
    /// `.idle` while the first was still waiting; a dictation started then
    /// was torn down by the first cancel's cleanup when it resumed (#435
    /// review). The second cancel must join the first: one teardown and one
    /// cleanup, and presses stay ignored until that one is done.
    func test_a_second_cancel_joins_the_first_instead_of_finishing_early() async {
        let cancels = JoinedRun()
        let teardown = HeldTeardown()
        let bodies = RunCounter()

        let first = Task { @MainActor in
            await cancels.runOrJoin {
                bodies.count += 1
                await teardown.run()
            }
        }
        let deadline = Date().addingTimeInterval(5)
        while !teardown.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard teardown.isRunning else {
            teardown.finish()
            _ = await first.value
            return XCTFail("setup: the first cancel never reached its teardown")
        }
        XCTAssertTrue(cancels.isRunning, "setup: the first cancel is tearing down")

        let second = Task { @MainActor () -> Bool in
            let ran = await cancels.runOrJoin { bodies.count += 1 }
            bodies.secondReturned = true
            return ran
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(bodies.secondReturned, "the second cancel waits for the first's teardown")
        XCTAssertTrue(cancels.isRunning, "presses stay ignored while the first is still waiting")

        teardown.finish()
        let firstRan = await first.value
        let secondRan = await second.value
        XCTAssertTrue(firstRan)
        XCTAssertFalse(secondRan, "the second cancel joined instead of running its own cleanup")
        XCTAssertEqual(bodies.count, 1, "one teardown and one cleanup")
        XCTAssertFalse(cancels.isRunning, "presses work again once that one is done")

        // The next cancel (a later dictation's) runs its own body, and a
        // quit's bounded join gives up on a teardown that is stuck.
        let ranAgain = await cancels.runOrJoin { bodies.count += 1 }
        XCTAssertTrue(ranAgain)
        XCTAssertEqual(bodies.count, 2)

        let stuck = HeldTeardown()
        let stuckCancel = Task { @MainActor in
            await cancels.runOrJoin { await stuck.run() }
        }
        let stuckDeadline = Date().addingTimeInterval(5)
        while !stuck.isRunning, Date() < stuckDeadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let started = Date()
        let joinedInTime = await DictationController.waitAtMost(0.1) {
            await cancels.runOrJoin {}
        }
        XCTAssertFalse(joinedInTime, "a quit's bounded join stops waiting for a stuck teardown")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertTrue(cancels.isRunning, "the stuck cancel itself carries on")
        stuck.finish()
        _ = await stuckCancel.value
        XCTAssertFalse(cancels.isRunning)
    }

    /// The recorder's teardown has no timeout of its own and can block on
    /// the CoreAudio HAL. A stop or cancel waits for it at most
    /// `recorderTeardownDeadline`, then carries on, so a teardown that never
    /// returns cannot leave every later press ignored until relaunch. Its
    /// completion after the deadline must change nothing: in particular it
    /// must not resume the wait a second time, which would trap.
    func test_a_teardown_that_overruns_the_deadline_is_left_behind() async {
        let teardown = HeldTeardown()
        let started = Date()
        let inTime = await DictationController.waitAtMost(0.1) {
            await teardown.run()
        }
        XCTAssertFalse(inTime, "the wait must give up at the deadline")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5,
                          "the wait must end at the deadline, not with the teardown")
        XCTAssertTrue(teardown.isRunning, "the teardown itself keeps running")

        teardown.finish()
        let deadline = Date().addingTimeInterval(5)
        while !teardown.didFinish, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(teardown.didFinish, "the late completion ran, and was a no-op")

        let quick = Date()
        let fast = await DictationController.waitAtMost(30) {}
        XCTAssertTrue(fast, "a teardown that returns in time is reported as such")
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

/// What the cancel bodies in the join test did.
@MainActor
private final class RunCounter {
    var count = 0
    var secondReturned = false
}
