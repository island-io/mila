import XCTest
@testable import Mila

/// Per-meeting background notes (`LiveAISettings.meetingContext`).
///
/// Origin: a user pasted a meeting agenda into Settings → Live AI →
/// System prompt, which is a PERMANENT template. Every later recording was
/// therefore handed the previous meeting's agenda as context, and the model
/// returned a blended "previous call + this call" summary plus action items
/// lifted straight from the stale agenda (all stamped
/// `timestamp_seconds: 0`, since nobody ever said them out loud). The fix
/// is a separate, in-memory, cleared-at-stop context field — these tests
/// pin both halves: the wire format the model sees, and the lifecycle that
/// keeps one meeting's notes out of the next one.
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
        let (session, live, prompts) = makeSession(suite: "LiveAIMeetingContextTests.send")
        live.meetingContext = "Attendees: Dana, Yaron. FF = feature flag."

        session.feed(transcript: "So about the flags.", immediate: true)
        await waitUntilIdle(session)

        XCTAssertEqual(prompts.value.count, 1)
        XCTAssertTrue(prompts.value[0].contains("FF = feature flag."),
                      "meeting notes must be part of the tick prompt")
    }

    /// Notes are read at TICK time, not snapshotted at `start()` — a
    /// meeting-detector auto-start beats the user to the pane, so the
    /// agenda usually arrives a minute into the recording. Clearing them
    /// mid-recording must likewise take effect on the next tick.
    func test_context_isReadPerTick_notSnapshottedAtStart() async {
        let (session, live, prompts) = makeSession(suite: "LiveAIMeetingContextTests.pertick")

        // Tick 1: no notes yet (pasted after the recording started).
        session.feed(transcript: "First chunk.", immediate: true)
        await waitUntilIdle(session)
        XCTAssertFalse(prompts.value[0].contains("BACKGROUND NOTES"))

        // Tick 2: notes pasted mid-recording.
        live.meetingContext = "Q3 planning agenda"
        session.feed(transcript: "First chunk. Second chunk.", immediate: true)
        await waitUntilIdle(session)
        XCTAssertTrue(prompts.value[1].contains("Q3 planning agenda"))

        // Tick 3: cleared again.
        live.meetingContext = ""
        session.feed(transcript: "First chunk. Second chunk. Third chunk.", immediate: true)
        await waitUntilIdle(session)
        XCTAssertFalse(prompts.value[2].contains("BACKGROUND NOTES"))
    }

    // MARK: - Lifecycle

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
        let dump = UserDefaults(suiteName: suite)!.dictionaryRepresentation()
        for (key, value) in dump {
            if let string = value as? String {
                XCTAssertFalse(string.contains("Sensitive agenda"),
                               "notes leaked into UserDefaults under \(key)")
            }
        }
    }

    // MARK: - Helpers

    /// Box so the escaping `performCall` stub can record prompts without
    /// capturing a mutable local.
    private final class Prompts {
        var value: [String] = []
    }

    private func makeSession(suite: String) -> (LiveAISession, LiveAISettings, Prompts) {
        UserDefaults().removePersistentDomain(forName: "\(suite).llm")
        UserDefaults().removePersistentDomain(forName: "\(suite).live")
        let llm = LLMSettings(defaults: UserDefaults(suiteName: "\(suite).llm")!)
        llm.tool = .claude
        let live = LiveAISettings(defaults: UserDefaults(suiteName: "\(suite).live")!)
        live.enabled = true
        live.llmMinIntervalSeconds = 0   // no throttle floor in these tests

        let prompts = Prompts()
        let session = LiveAISession(llmSettings: llm, liveAISettings: live)
        session.performCall = { call in
            prompts.value.append(call.prompt)
            return #"{"summary":"ok","items":[]}"#
        }
        session.start()
        return (session, live, prompts)
    }

    /// Spin until the in-flight tick clears. The stub returns instantly, so
    /// this resolves in a few hops; the timeout only guards a hang.
    private func waitUntilIdle(_ session: LiveAISession,
                               timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while session.isThinking && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
