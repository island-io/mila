import Foundation
import XCTest
@testable import Mila

/// Deleting a line from the live transcript has to reach the Live AI
/// conversation, not just the next prompt (issue #239).
///
/// `LiveTranscriber.removeSegment(id:)` already took a line out of everywhere
/// the user can see — the pane, `live/current.json`, the SRT, the transcript
/// saved at Stop. It did not reach the one place they cannot: the model's own
/// conversation. Every Live AI tick after the first is `claude --resume
/// <uuid>`, which replays every earlier turn, so a line already shipped stayed
/// in history however the next prompt was worded, and kept informing the
/// summary and action items for the rest of the meeting.
///
/// `bugbot-rules/deleted-data-stays-deleted.md` treats a live-transcript
/// delete as a privacy action rather than a cache eviction, and #125's issue
/// listed "the in-flight Live-AI summary payload" among the places a deletion
/// has to reach. It was the one that got missed.
///
/// These pin the session lifecycle. The transcriber half (`deletionCount`
/// moving) lives in `LiveTranscriptLineDeleteTests`; the five lines of feed-
/// loop wiring that join them sit in `MilaApp.wireLiveAIPipeline`, which needs
/// a real capture session and is not reachable from a unit test.
@MainActor
final class LiveAIDeletedLineSessionTests: XCTestCase {

    /// The negative control. Two ticks establish and then resume a session
    /// that has been told "Two."; a deletion must make the third tick open a
    /// NEW conversation, so nothing can replay the removed line.
    ///
    /// Delete `noteTranscriptEdited()`'s body and this fails on the very first
    /// assertion: the tick resumes the session that still contains "Two."
    func test_deleting_a_line_abandons_the_session_that_was_told_about_it() async {
        let (session, calls) = makeSession(suite: "LiveAIDeletedLineSessionTests.abandon")

        session.feed(transcript: "[00:00] One.", immediate: true)
        await waitUntilIdle(session)
        session.feed(transcript: "[00:00] One.\n[00:05] Two.", immediate: true)
        await waitUntilIdle(session)

        XCTAssertEqual(kind(calls.value[0].session), "new")
        XCTAssertEqual(kind(calls.value[1].session), "resume",
                       "precondition: the second tick resumes, which is what carries history")
        let doomed = uuid(calls.value[1].session)

        // The user deletes "Two." — the transcriber drops it and the feed loop
        // reports the edit before feeding the shortened transcript.
        session.noteTranscriptEdited()
        session.feed(transcript: "[00:00] One.", immediate: true)
        await waitUntilIdle(session)

        XCTAssertEqual(kind(calls.value[2].session), "new",
                       "a deleted line must open a new conversation, not resume the one holding it")
        XCTAssertNotEqual(uuid(calls.value[2].session), doomed,
                          "the abandoned session id must not be reused")
        // The assertion that actually encodes the privacy property: what the
        // model is handed from here on contains the surviving line and not the
        // deleted one.
        XCTAssertTrue(calls.value[2].transcript.contains("One."))
        XCTAssertFalse(calls.value[2].transcript.contains("Two."),
                       "the deleted line must not be re-sent to the fresh session either")
    }

    /// After a restart the next tick must ship the WHOLE remaining transcript,
    /// not a delta computed against what the abandoned session was told —
    /// the new conversation has never heard any of it.
    func test_the_fresh_session_is_given_the_whole_remaining_transcript() async {
        let (session, calls) = makeSession(suite: "LiveAIDeletedLineSessionTests.full")

        session.feed(transcript: "[00:00] One.\n[00:05] Two.\n[00:09] Three.", immediate: true)
        await waitUntilIdle(session)

        session.noteTranscriptEdited()
        session.feed(transcript: "[00:00] One.\n[00:09] Three.", immediate: true)
        await waitUntilIdle(session)

        XCTAssertEqual(kind(calls.value[1].session), "new")
        XCTAssertTrue(calls.value[1].transcript.contains("One."),
                      "a delta against the abandoned session would have omitted the earlier lines")
        XCTAssertTrue(calls.value[1].transcript.contains("Three."))
        XCTAssertFalse(calls.value[1].transcript.contains("Two."))
    }

    /// Deleting five lines in a row must cost ONE new session, not five.
    /// Restarting mints a uuid and clears `sessionEstablished`; until a tick
    /// actually succeeds no call has been made, so a second deletion just
    /// replaces an unused id. This is what makes the eager restart affordable.
    func test_several_deletions_between_ticks_cost_one_restart() async {
        let (session, calls) = makeSession(suite: "LiveAIDeletedLineSessionTests.coalesce")

        session.feed(transcript: "[00:00] One.\n[00:05] Two.\n[00:09] Three.", immediate: true)
        await waitUntilIdle(session)
        XCTAssertEqual(calls.value.count, 1)

        session.noteTranscriptEdited()
        session.noteTranscriptEdited()
        session.noteTranscriptEdited()
        session.feed(transcript: "[00:00] One.", immediate: true)
        await waitUntilIdle(session)

        XCTAssertEqual(calls.value.count, 2,
                       "the deletions themselves must not each trigger an LLM call")
        XCTAssertEqual(kind(calls.value[1].session), "new")
    }

    /// The cost guard in the other direction: an ordinary tick with no
    /// deletion must keep resuming. If this ever fails, every tick is paying
    /// for a fresh session and a full-transcript re-send.
    func test_without_a_deletion_ticks_keep_resuming() async {
        let (session, calls) = makeSession(suite: "LiveAIDeletedLineSessionTests.noop")

        session.feed(transcript: "[00:00] One.", immediate: true)
        await waitUntilIdle(session)
        session.feed(transcript: "[00:00] One.\n[00:05] Two.", immediate: true)
        await waitUntilIdle(session)
        session.feed(transcript: "[00:00] One.\n[00:05] Two.\n[00:09] Three.", immediate: true)
        await waitUntilIdle(session)

        XCTAssertEqual(kind(calls.value[0].session), "new")
        XCTAssertEqual(kind(calls.value[1].session), "resume")
        XCTAssertEqual(kind(calls.value[2].session), "resume")
        XCTAssertEqual(uuid(calls.value[1].session), uuid(calls.value[0].session))
        XCTAssertEqual(uuid(calls.value[2].session), uuid(calls.value[0].session))
    }

    /// Stateless tools carry no conversation, so there is nothing to abandon
    /// and the call must stay a no-op — including not disturbing the delta
    /// bookkeeping the stateless path shares.
    func test_deletion_is_a_no_op_for_a_stateless_tool() async {
        let (session, calls) = makeSession(suite: "LiveAIDeletedLineSessionTests.stateless",
                                           tool: .cursor)

        session.feed(transcript: "[00:00] One.", immediate: true)
        await waitUntilIdle(session)
        XCTAssertEqual(kind(calls.value[0].session), "none",
                       "precondition: cursor runs one-shot, with no session id")

        session.noteTranscriptEdited()
        session.feed(transcript: "[00:00] Two.", immediate: true)
        await waitUntilIdle(session)

        XCTAssertEqual(calls.value.count, 2)
        XCTAssertEqual(kind(calls.value[1].session), "none",
                       "a stateless tool must not suddenly acquire a session id")
        XCTAssertTrue(calls.value[1].transcript.contains("Two."))
    }

    /// A deletion while a tick is IN FLIGHT must not wedge Live AI -- and must
    /// still recover onto a new session.
    ///
    /// This is the failure mode `noteTranscriptEdited()` introduced and the
    /// `defer` in `kick()`'s task fixes. Both "session changed mid-flight"
    /// guards `return` out of that closure, which used to skip the tail that
    /// clears `inFlight`. Nothing could reach them before: `kick()` only runs
    /// when `inFlight == nil`, so the notes-edit restart cannot land mid-call,
    /// and `cancel()` clears `inFlight` itself. A per-line delete can, and a
    /// stranded `inFlight` makes `scheduleKick` coalesce every later tick
    /// behind a task that will never clear -- Live AI silently stops for the
    /// rest of the meeting.
    ///
    /// Revert the `defer` and this fails at the strand check below.
    /// (CodeRabbit raised the mechanism on #242; verified against the code
    /// before fixing.)
    ///
    /// There is deliberately no wall-clock bound left in here. The chain this
    /// used to wait on -- gate release -> the in-flight task finishes -> its
    /// `defer` runs -> `coalesced` is observed -> `scheduleKick` fires -> the
    /// new tick records its call -- is awaited one link at a time instead, so
    /// a wedge is read off the state rather than inferred from elapsed time.
    /// See `waitUntil` for why the bound had to go rather than be re-tuned.
    func test_deleting_during_an_in_flight_tick_recovers_on_a_new_session() async {
        let gate = Gate()
        defer { gate.releaseAll() }
        let (session, calls) = makeSession(suite: "LiveAIDeletedLineSessionTests.inflight",
                                           hold: gate)

        session.feed(transcript: "[00:00] One.\n[00:05] Two.", immediate: true)
        // `kick()` fills the slot synchronously, so "a tick launched at all"
        // is a fact the instant `feed` returns -- assert it here, where a
        // failure is immediate, rather than folding it into a wait.
        guard let dropped = session.inFlightTickForTesting else {
            XCTFail("precondition: the first tick must occupy the in-flight slot")
            return
        }
        // Then let the gate say when that tick is inside the runner; its only
        // suspension point is the park, so it must arrive. Inferring this from
        // `calls.value.count` instead left a window in which `release(1)`
        // below ran before the park had recorded its continuation -- a lost
        // wakeup, which strands the tick and is indistinguishable from the
        // product wedge this test is about. See `Gate`.
        await gate.awaitPark(1)

        // The user deletes "Two." while that call is still running, and the
        // feed loop follows with the shortened transcript -- which coalesces,
        // because a call is in flight.
        session.noteTranscriptEdited()
        session.feed(transcript: "[00:00] One.", immediate: true)

        gate.release(1)
        // Await the dropped tick itself. It has to end -- the gate just
        // released its only suspension point -- and everything under test
        // happens in its `defer`, which runs before the task completes.
        _ = await dropped.value

        // The wedge is now a fact rather than a deadline: the tick has
        // finished, so if the slot still holds it, it is stranded, and it is
        // stranded *now*. No amount of extra waiting would change the answer,
        // which is exactly what made a bound the wrong instrument here.
        //
        // The replacement is created inside that same `defer`, so if one was
        // scheduled it is in the slot by now -- but nothing parks it (only
        // call 1 parks), so it may equally have run to completion already, in
        // which case the slot is empty and the call count below is what
        // reports success.
        if let replacement = session.inFlightTickForTesting {
            if replacement == dropped {
                XCTFail("Live AI wedged: the dropped tick left `inFlight` set, so every "
                        + "later tick coalesces behind a task that never clears and Live "
                        + "AI is silently dead for the rest of the meeting")
                return
            }
            _ = await replacement.value
        }

        guard calls.value.count == 2 else {
            XCTFail("the slot was released but the coalesced re-kick the deletion "
                    + "queued never ran, so the post-deletion transcript never "
                    + "reaches the model (recorded \(calls.value.count) call(s))")
            return
        }
        XCTAssertEqual(kind(calls.value[1].session), "new",
                       "the replacement tick must open a new session, not resume the abandoned one")
        XCTAssertTrue(calls.value[1].transcript.contains("One."))
        XCTAssertFalse(calls.value[1].transcript.contains("Two."),
                       "the recovery tick must carry the post-deletion transcript")
        XCTAssertFalse(session.isThinking, "the thinking indicator must not be left on")
    }

    /// The mirror-image hazard, and the reason the `defer` is gated on
    /// cancellation rather than unconditional.
    ///
    /// `cancel()` cancels the running tick AND clears `inFlight` itself, then
    /// `start()` can put the NEXT recording's first tick into that slot --
    /// ordinary, because `stopRecording` frees the record button without
    /// waiting for the LLM. If the abandoned tick cleared the slot from its
    /// own `defer`, it would clobber the newer handle: Live AI would then be
    /// running with `inFlight == nil`, free to launch a second concurrent
    /// `claude` on the same session id.
    ///
    /// The old code was safe here only by accident -- the id guards returned
    /// before the tail, and `cancel()` nils `sessionID`. Making the cleanup
    /// unconditional removed that accident; `!Task.isCancelled` restores it
    /// deliberately, matching `PostRecordingCoordinator.sendToLLM`.
    /// (Bugbot on #242, a86b392.)
    func test_a_cancelled_tick_does_not_clobber_the_next_recordings_tick() async {
        let gate = Gate(parkThrough: 2)
        defer { gate.releaseAll() }
        let (session, calls) = makeSession(suite: "LiveAIDeletedLineSessionTests.clobber",
                                           hold: gate)

        session.feed(transcript: "[00:00] First meeting.", immediate: true)
        guard let abandoned = session.inFlightTickForTesting else {
            XCTFail("precondition: recording one's tick must be in flight")
            return
        }
        await gate.awaitPark(1)

        // The recording stops and a new one starts before the LLM answers.
        session.cancel()
        session.start()
        session.feed(transcript: "[00:00] Second meeting.", immediate: true)
        guard let live = session.inFlightTickForTesting, live != abandoned else {
            XCTFail("precondition: the new recording's tick must have started and "
                    + "must own the in-flight slot")
            return
        }
        await gate.awaitPark(2)

        // Let the ABANDONED tick finish, underneath the live one, and wait for
        // it to actually be finished before opening the quiet windows below.
        // Polling for its side effects instead meant the windows also had to
        // cover it finishing at all, which weakens exactly the assertions that
        // depend on the window being quiet for a reason.
        gate.release(1)
        _ = await abandoned.value

        // Asserted as a negative, because the harm is state being cleared that
        // belongs to the tick still running.
        //
        // `quietWindow`, and these two are the only waits in the suite that
        // still take a clock at all: they are watching for something that must
        // never happen, so the timeout is a window of required quiet rather
        // than a deadline. `waitUntil` returns the moment its condition holds,
        // so the full budget is spent only when the assertion PASSES —
        // widening it would slow every green run and would make a spurious
        // pass more likely, not less. See `quietWindow`.
        let wentIdle = await waitUntil(timeout: Self.quietWindow) { !session.isThinking }
        XCTAssertFalse(wentIdle,
                       "the cancelled tick cleared `isThinking` while the new recording's tick was still running")

        let startedAThird = await waitUntil(timeout: Self.quietWindow) { calls.value.count == 3 }
        XCTAssertFalse(startedAThird,
                       "`inFlight` was clobbered: a third call started while the second was still in flight")

        // And the surviving tick still completes normally once released.
        gate.release(2)
        _ = await live.value
        XCTAssertFalse(session.isThinking,
                       "the new recording's tick must still finish and clear state on its own")
        XCTAssertEqual(calls.value.count, 2,
                       "no further call may have started: nothing fed the session after "
                       + "recording two's first tick")
    }

    // MARK: - Helpers
    //
    // Deliberately the same shape as `LiveAIMeetingContextTests`, which pins
    // the sibling restart-on-notes-edit behaviour these tests mirror.

    private final class Calls {
        var value: [LiveAISession.LLMCall] = []
    }

    /// Lets a test park `performCall` so something can land while a tick is
    /// genuinely in flight, rather than in the gap between ticks.
    ///
    /// Calls numbered up to `parkThrough` suspend until `release(_:)` names
    /// their own index, so a test can let an EARLIER tick finish while a later
    /// one is still parked -- the only way to reproduce an abandoned tick
    /// completing underneath its replacement.
    ///
    /// **Order-independent by construction, which is the whole point.** The
    /// two halves of the handshake do not necessarily run in the same place:
    /// `park` records its continuation inside `withCheckedContinuation`, whose
    /// body only stays on the caller's executor on a toolchain carrying
    /// SE-0420's `isolation:` parameter, while `release` is called straight
    /// from the @MainActor test body. If the store lands after the release,
    /// the wakeup is lost, the parked call never resumes, and `inFlight` is
    /// never cleared -- a symptom identical to the product wedge these tests
    /// exist to catch, permanent in the same way ("a wedge never completes it
    /// however long we wait"), and machine-sensitive in exactly the way a
    /// loaded CI runner is. That is issue #256's failure, and the version of
    /// this gate that had `release(_:)` drop an unmatched wakeup on the floor
    /// was the only one of the four gates in these suites that could lose it
    /// (`ConcurrencyProbe.released` and `TestGate.isOpen` both guard the same
    /// ordering; `OpenAICompatibleTests`' stub takes a lock).
    ///
    /// So: a `release(i)` that arrives before call `i` parks is remembered and
    /// the park returns immediately, `awaitPark(_:)` lets a test wait for a
    /// call to be genuinely parked instead of inferring it from the recorded
    /// call count, and a lock makes both hold wherever the continuation body
    /// runs. Deliberately a lock rather than an actor annotation: assuming
    /// isolation would serialise the handshake is the assumption that broke,
    /// and it is not one a reader should have to re-derive from the nesting.
    private final class Gate {
        /// Calls with an index at or below this park; later ones run straight
        /// through. `let`, so it cannot be mutated once a call might read it.
        let parkThrough: Int

        /// Guards every field below. See the type comment: the
        /// `withCheckedContinuation` body and `release(_:)` are not reliably
        /// on the same executor, so the ordering is enforced here rather than
        /// assumed.
        private let lock = NSLock()
        private var parked: [Int: CheckedContinuation<Void, Never>] = [:]
        /// `release(i)` calls that arrived before call `i` parked.
        private var releasedEarly: Set<Int> = []
        /// Indices that have reached `park`, plus anyone waiting to hear it.
        private var arrived: Set<Int> = []
        private var arrivalWaiters: [(index: Int, cont: CheckedContinuation<Void, Never>)] = []
        /// Set by `releaseAll()`: after the drain nothing may park again.
        private var draining = false

        init(parkThrough: Int = 1) { self.parkThrough = parkThrough }

        func park(_ index: Int) async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                arrived.insert(index)
                let waking = arrivalWaiters.filter { $0.index == index }
                arrivalWaiters.removeAll { $0.index == index }
                // A release that beat this park still counts.
                let straightThrough = draining || releasedEarly.remove(index) != nil
                if !straightThrough { parked[index] = c }
                lock.unlock()
                for w in waking { w.cont.resume() }
                if straightThrough { c.resume() }
            }
        }

        /// Let one call proceed, whether or not it has parked yet.
        /// Deliberately a continuation rather than a polled flag: a cancelled
        /// task's `Task.sleep` returns immediately, so a polling loop would
        /// spin the main actor hot for exactly the tick this suite needs to
        /// keep suspended.
        func release(_ index: Int) {
            lock.lock()
            let parkedCall = parked.removeValue(forKey: index)
            if parkedCall == nil { releasedEarly.insert(index) }
            lock.unlock()
            parkedCall?.resume()
        }

        /// Suspend until call `index` is parked inside the stub, so a test can
        /// act while a tick is demonstrably inside the runner without polling
        /// a clock for it. Returns immediately if it already parked. Same
        /// shape as `ConcurrencyProbe.waitUntilCurrent` in
        /// `RecordingSummarizerBackfillTests`.
        func awaitPark(_ index: Int) async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if arrived.contains(index) || draining {
                    lock.unlock()
                    c.resume()
                } else {
                    arrivalWaiters.append((index: index, cont: c))
                    lock.unlock()
                }
            }
        }

        /// Drain anything still parked or still waiting, so a failed assertion
        /// leaves no suspended task behind.
        func releaseAll() {
            lock.lock()
            draining = true
            let stillParked = parked
            let stillWaiting = arrivalWaiters
            parked.removeAll()
            arrivalWaiters.removeAll()
            releasedEarly.removeAll()
            lock.unlock()
            for (_, c) in stillParked { c.resume() }
            for w in stillWaiting { w.cont.resume() }
        }
    }

    private func kind(_ session: LLMSession) -> String {
        switch session {
        case .none:   return "none"
        case .new:    return "new"
        case .resume: return "resume"
        }
    }

    private func uuid(_ session: LLMSession) -> UUID? {
        switch session {
        case .none:                         return nil
        case .new(let id), .resume(let id): return id
        }
    }

    private func makeSession(suite: String,
                             tool: LLMTool = .claude,
                             hold: Gate? = nil) -> (LiveAISession, Calls) {
        UserDefaults().removePersistentDomain(forName: "\(suite).llm")
        UserDefaults().removePersistentDomain(forName: "\(suite).live")
        let llm = LLMSettings(defaults: UserDefaults(suiteName: "\(suite).llm")!)
        llm.tool = tool
        let live = LiveAISettings(defaults: UserDefaults(suiteName: "\(suite).live")!)
        live.enabled = true
        live.llmMinIntervalSeconds = 0

        let calls = Calls()
        let session = LiveAISession(llmSettings: llm, liveAISettings: live)
        // Snapshot the gate's threshold here, on the main actor, rather than
        // reading it back off `hold` from inside the stub -- the stub's own
        // isolation is whatever the closure inherits, and this keeps a plain
        // `Int` in the capture list either way.
        let parkThrough = hold?.parkThrough ?? 0
        session.performCall = { call in
            calls.value.append(call)
            // Park early calls so the test can act while a tick is
            // demonstrably inside the runner.
            if let hold {
                let index = calls.value.count   // 1-based: appended just above
                if index <= parkThrough { await hold.park(index) }
            }
            return #"{"summary":"ok","items":[]}"#
        }
        session.start()
        return (session, calls)
    }

    /// Window for watching that something must NOT happen (the caller asserts
    /// the result is `false`).
    ///
    /// This is the OPPOSITE case and it must stay short. `waitUntil` returns
    /// the instant its condition holds, so a negative assertion only ever
    /// spends its whole budget when it is **passing** — raising it would add
    /// that budget to every green run for no gain at all. And a longer window
    /// gives unrelated scheduling more chance to satisfy the condition, so it
    /// makes a spurious *pass* more likely, not less. 1s is already ~1000x the
    /// scale these transitions happen on.
    private static let quietWindow: TimeInterval = 1

    /// Spin until `condition` holds, or the window expires. Returns whether
    /// it held -- callers assert on that rather than hanging the suite.
    ///
    /// **For negative assertions only**, which is why `timeout` is now
    /// required rather than defaulted. It used to default to a `mustHappen`
    /// bound of 30s for the positive waits; that constant is deliberately
    /// deleted rather than re-tuned. A bound on a positive wait cannot tell a
    /// wedge from a loaded runner -- both look like "it hasn't happened yet"
    /// -- so no value is correct, and picking one was wrong at 5s (#242) and
    /// wrong again at 30s (#251, tripped by #256). Every positive wait in this
    /// suite now awaits the task it is actually reasoning about
    /// (`LiveAISession.inFlightTickForTesting`, `Gate.awaitPark`,
    /// `waitUntilIdle`), so a wedge is read off the state at the moment it
    /// becomes true and a slow machine simply takes longer. Requiring the
    /// argument keeps a future positive wait from quietly inheriting a number.
    private func waitUntil(timeout: TimeInterval,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    /// Settle whatever tick the preceding `feed` started, by awaiting the task
    /// itself rather than polling `isThinking` against a clock.
    ///
    /// `makeSession` sets `llmMinIntervalSeconds = 0`, so every `feed` here
    /// either launches a tick synchronously or declines to (an empty delta) --
    /// there is never a `pendingKickTask` sleeping out a throttle floor with
    /// the slot empty, which is the one case where "no task" would not mean
    /// "settled". `nil` therefore means already settled.
    ///
    /// The loop drains a coalesced follow-up too, and stops as soon as the
    /// slot stops changing. That last part matters: a STRANDED slot -- the
    /// wedge this suite pins, a finished task still occupying `inFlight` --
    /// returns immediately and lets the assertions report it, rather than
    /// spinning hot the way `LiveAISession.awaitFinalTick`'s
    /// `while let handle = inFlight` would.
    private func waitUntilIdle(_ session: LiveAISession) async {
        var previous: Task<Void, Never>?
        while let tick = session.inFlightTickForTesting {
            if let previous, previous == tick { break }
            _ = await tick.value
            previous = tick
        }
    }
}
