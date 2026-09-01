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

        gate.isOpen = true

        let recovered = await waitUntil(timeout: 5) { calls.value.count == 2 }
        XCTAssertTrue(recovered,
                      "Live AI wedged: the dropped tick left `inFlight` set, so every later tick coalesced behind a task that never clears")
        XCTAssertEqual(kind(calls.value[1].session), "new",
                       "the replacement tick must open a new session, not resume the abandoned one")
        XCTAssertTrue(calls.value[1].transcript.contains("One."))
        XCTAssertFalse(calls.value[1].transcript.contains("Two."),
                       "the recovery tick must carry the post-deletion transcript")
        XCTAssertFalse(session.isThinking, "the thinking indicator must not be left on")
    }

    // MARK: - Helpers
    //
    // Deliberately the same shape as `LiveAIMeetingContextTests`, which pins
    // the sibling restart-on-notes-edit behaviour these tests mirror.

    private final class Calls {
        var value: [LiveAISession.LLMCall] = []
    }

    /// Lets a test park the first `performCall` so a deletion can land while a
    /// tick is genuinely in flight, rather than in the gap between ticks.
    private final class Gate {
        var isOpen = false
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
            // Park the FIRST call only, so the test can act while the tick is
            // demonstrably inside the runner.
            if let hold, calls.value.count == 1 {
                while !hold.isOpen {
                    try? await Task.sleep(nanoseconds: 500_000)
                }
            }
            return #"{"summary":"ok","items":[]}"#
        }
        session.start()
        return (session, calls)
    }

    /// Spin until `condition` holds, or the timeout expires. Returns whether
    /// it held -- callers assert on that rather than hanging the suite.
    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    private func waitUntilIdle(_ session: LiveAISession,
                               timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while session.isThinking && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
