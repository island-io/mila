import XCTest
@testable import Mila

/// Per-meeting background notes (`LiveAISettings.meetingContext`).
///
/// Origin: a user pasted a meeting agenda into the Live AI system prompt
/// (Settings → AI Features → Live AI mode), which is a PERMANENT template. Every later recording was
/// therefore handed the previous meeting's agenda as context, and the model
/// returned a blended "previous call + this call" summary plus action items
/// lifted straight from the stale agenda (all stamped
/// `timestamp_seconds: 0`, since nobody ever said them out loud). The fix
/// is a separate, in-memory, cleared-at-stop context field — these tests
/// pin all three parts: the wire format the model sees, the session
/// lifecycle that makes an edit actually take effect, and the persistence
/// invariant that keeps one meeting's notes out of the next one.
@MainActor
final class LiveAIMeetingContextTests: XCTestCase {

    // MARK: - Wire format (pure)

    func test_promptWithContext_noContext_returnsPromptUnchanged() {
        let prompt = "You are Mila. Output JSON."
        XCTAssertEqual(LiveAISession.promptWithContext(prompt, context: ""), prompt)
        XCTAssertEqual(LiveAISession.promptWithContext(prompt, context: "   \n\t "), prompt,
                       "whitespace-only notes must not add an empty BACKGROUND block")
    }

    func test_promptWithContext_fencesNotesAsNonTranscript() {
        let composed = LiveAISession.promptWithContext(
            "You are Mila. Output JSON.",
            context: "Agenda: Mor's team in Canada. LaunchDarkly — who takes it?")

        XCTAssertTrue(composed.hasPrefix("You are Mila. Output JSON."),
                      "the user's prompt stays first so the JSON contract leads")
        XCTAssertTrue(composed.contains("Agenda: Mor's team in Canada."))
        // The guard rails are the load-bearing part: an agenda reads like a
        // transcript of decisions already taken, so the model has to be told
        // it is neither transcript, nor summary material, nor an item source.
        XCTAssertTrue(composed.contains("NOT part of the transcript"))
        XCTAssertTrue(composed.contains("Do NOT summarise the notes"))
        XCTAssertTrue(composed.contains("do NOT turn them into action items"))
    }

    // MARK: - Wiring through a real tick

    /// Drives the REAL `feed → scheduleKick → kick` path with a stubbed
    /// `performCall`, and asserts the notes reach the prompt the CLI would
    /// have been given.
    func test_tick_sendsMeetingContextInPrompt() async {
        let (session, live, calls) = makeSession(suite: "LiveAIMeetingContextTests.send")
        live.meetingContext = "Attendees: Dana, Yaron. FF = feature flag."

        session.feed(transcript: "So about the flags.", immediate: true)
        await waitUntilIdle(session)

        XCTAssertEqual(calls.value.count, 1)
        XCTAssertTrue(calls.value[0].prompt.contains("FF = feature flag."),
                      "meeting notes must be part of the tick prompt")
    }

    /// Notes are read at TICK time, not snapshotted at `start()` — a
    /// meeting-detector auto-start beats the user to the pane, so the
    /// agenda usually arrives a minute into the recording.
    func test_context_isReadPerTick_notSnapshottedAtStart() async {
        let (session, live, calls) = makeSession(suite: "LiveAIMeetingContextTests.pertick")

        // Tick 1: no notes yet (pasted after the recording started).
        session.feed(transcript: "First chunk.", immediate: true)
        await waitUntilIdle(session)
        XCTAssertFalse(calls.value[0].prompt.contains("BACKGROUND NOTES"))

        // Tick 2: notes pasted mid-recording.
        live.meetingContext = "Q3 planning agenda"
        session.feed(transcript: "First chunk. Second chunk.", immediate: true)
        await waitUntilIdle(session)
        XCTAssertTrue(calls.value[1].prompt.contains("Q3 planning agenda"))
    }

    // MARK: - Session lifecycle on a context change

    /// A mid-recording edit to the notes must restart the Claude session.
    /// In session mode the prompt is only half the story: a `--resume` tick
    /// carries every earlier turn, so notes already sent live on in the
    /// model's conversation history. Dropping the block from the next prompt
    /// would leave the model still reading the version the user just
    /// replaced — so the next tick opens a NEW session and re-ships the full
    /// transcript. (CodeRabbit on #111.)
    func test_editingContextMidRecording_restartsSession() async {
        let (session, live, calls) = makeSession(suite: "LiveAIMeetingContextTests.restart")

        live.meetingContext = "Agenda v1"
        session.feed(transcript: "One.", immediate: true)
        await waitUntilIdle(session)
        session.feed(transcript: "One. Two.", immediate: true)
        await waitUntilIdle(session)

        // Tick 1 creates the session; tick 2 resumes it with just the delta.
        XCTAssertEqual(kind(calls.value[0].session), "new")
        XCTAssertEqual(kind(calls.value[1].session), "resume")
        XCTAssertTrue(calls.value[1].prompt.contains("Agenda v1"))

        // Editing the notes forces a fresh session id...
        live.meetingContext = "Agenda v2"
        session.feed(transcript: "One. Two. Three.", immediate: true)
        await waitUntilIdle(session)

        XCTAssertEqual(kind(calls.value[2].session), "new",
                       "a notes edit must open a new session, not resume the one holding the old notes")
        XCTAssertNotEqual(uuid(calls.value[2].session), uuid(calls.value[0].session),
                          "the restarted session must have its own id")
        XCTAssertTrue(calls.value[2].prompt.contains("Agenda v2"))
        XCTAssertFalse(calls.value[2].prompt.contains("Agenda v1"))
        // ...and the whole transcript goes with it, since the new session
        // has no memory of the earlier chunks.
        XCTAssertTrue(calls.value[2].transcript.contains("One."))
        XCTAssertTrue(calls.value[2].transcript.contains("Three."))

        // An unchanged context resumes as normal — no gratuitous restart.
        session.feed(transcript: "One. Two. Three. Four.", immediate: true)
        await waitUntilIdle(session)
        XCTAssertEqual(kind(calls.value[3].session), "resume")
    }

    /// Clearing the notes counts as a change for the same reason: the model
    /// has to stop reading them, and in session mode that takes a new
    /// session.
    func test_clearingContextMidRecording_restartsSession() async {
        let (session, live, calls) = makeSession(suite: "LiveAIMeetingContextTests.clear")

        live.meetingContext = "Agenda"
        session.feed(transcript: "One.", immediate: true)
        await waitUntilIdle(session)

        live.meetingContext = ""
        session.feed(transcript: "One. Two.", immediate: true)
        await waitUntilIdle(session)

        XCTAssertEqual(kind(calls.value[1].session), "new",
                       "clearing notes must not leave them alive in conversation history")
        XCTAssertFalse(calls.value[1].prompt.contains("BACKGROUND NOTES"))
    }

    // MARK: - Persistence

    /// The anti-leak invariant: notes live in memory only. A relaunch (a
    /// fresh settings object over the same defaults suite) must not
    /// resurrect them — that persistence is exactly what made the
    /// prompt-editor workaround leak across meetings.
    func test_meetingContext_isNotPersisted() {
        let suite = "LiveAIMeetingContextTests.persist"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        let first = LiveAISettings(defaults: UserDefaults(suiteName: suite)!)
        first.meetingContext = "Sensitive agenda for one meeting"

        let relaunched = LiveAISettings(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(relaunched.meetingContext, "",
                       "per-meeting notes must not survive into a new app session")
        // Belt and braces: nothing under any key in that suite holds the text.
        for (key, value) in UserDefaults(suiteName: suite)!.dictionaryRepresentation() {
            if let string = value as? String {
                XCTAssertFalse(string.contains("Sensitive agenda"),
                               "notes leaked into UserDefaults under \(key)")
            }
        }
    }

    // MARK: - Helpers

    /// Box so the escaping `performCall` stub can record what it was handed
    /// without capturing a mutable local.
    private final class Calls {
        var value: [LiveAISession.LLMCall] = []
    }

    private func kind(_ session: LLMSession) -> String {
        switch session {
        case .none:      return "none"
        case .new:       return "new"
        case .resume:    return "resume"
        }
    }

    private func uuid(_ session: LLMSession) -> UUID? {
        switch session {
        case .none:                             return nil
        case .new(let id), .resume(let id):     return id
        }
    }

    private func makeSession(suite: String) -> (LiveAISession, LiveAISettings, Calls) {
        UserDefaults().removePersistentDomain(forName: "\(suite).llm")
        UserDefaults().removePersistentDomain(forName: "\(suite).live")
        let llm = LLMSettings(defaults: UserDefaults(suiteName: "\(suite).llm")!)
        llm.tool = .claude   // isConfigured == (tool != .none); also enables session/delta mode
        let live = LiveAISettings(defaults: UserDefaults(suiteName: suite + ".live")!)
        live.enabled = true
        live.llmMinIntervalSeconds = 0   // no throttle floor in these tests

        let calls = Calls()
        let session = LiveAISession(llmSettings: llm, liveAISettings: live)
        session.performCall = { call in
            calls.value.append(call)
            // Minimal valid envelope so parseEnvelope succeeds and the
            // success path runs (which is what records lastTranscriptSent /
            // lastContextSent and establishes the session).
            return #"{"summary":"ok","items":[]}"#
        }
        session.start()
        return (session, live, calls)
    }

    /// Settle whatever tick the preceding `feed` started, by awaiting the
    /// task itself rather than polling `isThinking` against a clock.
    ///
    /// This was a 2s deadline that "only guards a hang" — the same wall-clock
    /// bet that failed at 5s and then at 30s in the sibling suite
    /// (`LiveAIDeletedLineSessionTests`, issues #242 / #251 / #256). A bound
    /// on a positive wait cannot tell a hang from a loaded runner, so there is
    /// no value to pick; awaiting the task removes the question. A hang now
    /// belongs to the tick, where XCTest's own per-test limit reports it,
    /// rather than being silently swallowed by a `while` that just stops.
    ///
    /// `makeSession` sets `llmMinIntervalSeconds = 0`, so every `feed` here
    /// either launches a tick synchronously or declines to (an empty delta) —
    /// there is never a `pendingKickTask` sleeping out a throttle floor with
    /// the slot empty, which is the one case where "no task" would not mean
    /// "settled". The loop drains a coalesced follow-up too, and stops as soon
    /// as the slot stops changing, so a stranded slot returns immediately and
    /// lets the assertions report it instead of spinning hot.
    private func waitUntilIdle(_ session: LiveAISession) async {
        var previous: Task<Void, Never>?
        while let tick = session.inFlightTickForTesting {
            if let previous, previous == tick { break }
            _ = await tick.value
            previous = tick
        }
    }
}
