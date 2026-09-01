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
    /// Revert the `defer` and this hangs at the second wait. (CodeRabbit
    /// raised the mechanism on #242; verified against the code before fixing.)
    func test_deleting_during_an_in_flight_tick_recovers_on_a_new_session() async {
        let gate = Gate()
        defer { gate.releaseAll() }
        let (session, calls) = makeSession(suite: "LiveAIDeletedLineSessionTests.inflight",
                                           hold: gate)

        session.feed(transcript: "[00:00] One.\n[00:05] Two.", immediate: true)
        let started = await waitUntil { calls.value.count == 1 }
        XCTAssertTrue(started, "precondition: the first tick must actually be in flight")

        // The user deletes "Two." while that call is still running, and the
        // feed loop follows with the shortened transcript -- which coalesces,
        // because a call is in flight.
        session.noteTranscriptEdited()
        session.feed(transcript: "[00:00] One.", immediate: true)

        gate.release(1)

        // `mustHappen`, not a hand-picked 5s: this waits on a chain of six
        // hops (gate release -> the in-flight task finishes -> its `defer`
        // runs -> `coalesced` is observed -> `scheduleKick` fires -> the new
        // tick records its call), and a wedge never completes it however long
        // we wait. See `mustHappen`.
        let recovered = await waitUntil { calls.value.count == 2 }
        XCTAssertTrue(recovered,
                      "the replacement tick never ran within \(Int(Self.mustHappen))s. "
                      + "The behaviour under test is that a dropped tick must not "
                      + "strand `inFlight` — if it did, every later tick coalesces "
                      + "behind a task that never clears and Live AI is silently "
                      + "dead for the rest of the meeting")
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
        let gate = Gate()
        gate.parkThrough = 2
        defer { gate.releaseAll() }
        let (session, calls) = makeSession(suite: "LiveAIDeletedLineSessionTests.clobber",
                                           hold: gate)

        session.feed(transcript: "[00:00] First meeting.", immediate: true)
        let firstStarted = await waitUntil { calls.value.count == 1 }
        XCTAssertTrue(firstStarted,
                      "precondition: recording one's tick must be in flight")

        // The recording stops and a new one starts before the LLM answers.
        session.cancel()
        session.start()
        session.feed(transcript: "[00:00] Second meeting.", immediate: true)
        let secondStarted = await waitUntil { calls.value.count == 2 }
        XCTAssertTrue(secondStarted,
                      "precondition: the new recording's tick must have started")

        // Let the ABANDONED tick finish, underneath the live one.
        gate.release(1)

        // Asserted as a negative, because the harm is state being cleared that
        // belongs to the tick still running.
        //
        // `quietWindow`, deliberately NOT `mustHappen`: these two are watching
        // for something that must never happen, so the timeout is a window of
        // required quiet rather than a deadline. `waitUntil` returns the moment
        // its condition holds, so the full budget is spent only when the
        // assertion PASSES — widening it would slow every green run and would
        // make a spurious pass more likely, not less. See `quietWindow`.
        let wentIdle = await waitUntil(timeout: Self.quietWindow) { !session.isThinking }
        XCTAssertFalse(wentIdle,
                       "the cancelled tick cleared `isThinking` while the new recording's tick was still running")

        let startedAThird = await waitUntil(timeout: Self.quietWindow) { calls.value.count == 3 }
        XCTAssertFalse(startedAThird,
                       "`inFlight` was clobbered: a third call started while the second was still in flight")

        // And the surviving tick still completes normally once released.
        gate.release(2)
        let drained = await waitUntil { !session.isThinking }
        XCTAssertTrue(drained,
                      "the new recording's tick must still finish and clear state on its own")
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
    private final class Gate {
        var parkThrough = 1
        private var parked: [Int: CheckedContinuation<Void, Never>] = [:]

        func park(_ index: Int) async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                parked[index] = c
            }
        }

        /// Let one parked call proceed. Deliberately a continuation rather
        /// than a polled flag: a cancelled task's `Task.sleep` returns
        /// immediately, so a polling loop would spin the main actor hot for
        /// exactly the tick this suite needs to keep suspended.
        func release(_ index: Int) { parked.removeValue(forKey: index)?.resume() }

        /// Drain anything still parked, so a failed assertion leaves no
        /// suspended task behind.
        func releaseAll() {
            for (_, c) in parked { c.resume() }
            parked.removeAll()
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
        session.performCall = { call in
            calls.value.append(call)
            // Park early calls so the test can act while a tick is
            // demonstrably inside the runner.
            if let hold {
                let index = calls.value.count   // 1-based: appended just above
                if index <= hold.parkThrough { await hold.park(index) }
            }
            return #"{"summary":"ok","items":[]}"#
        }
        session.start()
        return (session, calls)
    }

    /// Bound for a wait on something that MUST happen (the caller asserts the
    /// result is `true`).
    ///
    /// Chosen on the principle that **the only way to exceed it is the failure
    /// mode under test**. Every such wait here is for state that a genuine bug
    /// leaves wrong *forever* — a wedged `inFlight` is never cleared, however
    /// long you wait — so a generous bound removes contention-induced failures
    /// without costing one bit of discriminating power. It is also free on a
    /// passing run: the condition holds in milliseconds, so this budget is
    /// spent only when the test is failing anyway.
    ///
    /// These were 2-5s, and the 5s one is what failed on a loaded CI runner
    /// while reporting "Live AI wedged" — a diagnosis that was simply false;
    /// the machine was slow (issue #250). Same mistake as the 5s pipe-drain
    /// bound #245 had to widen. **Do not re-tighten them.** 30s still fails
    /// fast against CI's 240s per-test allowance, and no test here makes more
    /// than three of these waits, so the worst case stays well inside it.
    private static let mustHappen: TimeInterval = 30

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

    /// Spin until `condition` holds, or the timeout expires. Returns whether
    /// it held -- callers assert on that rather than hanging the suite.
    ///
    /// Defaults to `mustHappen` because that is the common case; a caller
    /// asserting the result is `false` must pass `quietWindow` explicitly.
    private func waitUntil(timeout: TimeInterval = LiveAIDeletedLineSessionTests.mustHappen,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    /// Settle an in-flight tick. Same `mustHappen` reasoning: a session that
    /// never goes idle is broken, and the assertions after the call are what
    /// report it — this wait only has to avoid expiring on a slow runner.
    private func waitUntilIdle(_ session: LiveAISession,
                               timeout: TimeInterval = LiveAIDeletedLineSessionTests.mustHappen) async {
        let deadline = Date().addingTimeInterval(timeout)
        while session.isThinking && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
