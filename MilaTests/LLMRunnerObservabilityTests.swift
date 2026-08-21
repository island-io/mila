import XCTest
@testable import Mila

/// Issue #175 — "LLM CLI runs are unobservable".
///
/// `LLMRunner` now emits a start/end pair per invocation to the unified log.
/// The unified log itself isn't assertable from a unit test, so what these
/// tests pin is the part that matters and *is* pure: the helpers that build
/// every string handed to a `Logger`.
///
/// That is deliberately where the safety property lives. A transcript must
/// never reach the system log, and the way that is guaranteed is structural —
/// the only strings interpolated into a log line come from these functions,
/// and none of them can carry prompt or transcript text. So testing them is
/// testing the privacy invariant, not just formatting.
///
/// Kept out of `LLMRunnerTests` on purpose: that class also holds smoke tests
/// that invoke the real `claude` / `cursor-agent` / `gemini` binaries, so it
/// can't be run casually. Nothing here spawns a process.
final class LLMRunnerObservabilityTests: XCTestCase {

    // MARK: - redactedCommand

    /// The whole point: the flags survive so a user can see *what* was run,
    /// and the one argument that is the meeting transcript does not.
    func test_redacted_command_replaces_the_prompt_with_a_character_count() {
        let prompt = "Summarize this.\n\n---\nTranscript:\nWe agreed to ship on Friday."
        let args = LLMTool.claude.arguments(prompt: prompt, model: "haiku")
        let command = LLMRunner.redactedCommand(
            executable: URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            arguments: args,
            prompt: prompt)

        XCTAssertEqual(command,
                       "/opt/homebrew/bin/claude -p <prompt:\(prompt.count)c> --model haiku")
    }

    /// The privacy invariant stated directly, so a future refactor that stops
    /// redacting fails here rather than in a user's log.
    func test_redacted_command_never_contains_transcript_text() {
        let secret = "Acme is acquiring Globex for $4.2M"
        let prompt = LLMRunner.composedPrompt("Name this call.", transcript: secret)
        let session = UUID()
        let args = LLMTool.claude.arguments(prompt: prompt,
                                            model: nil,
                                            session: .resume(session))
        let command = LLMRunner.redactedCommand(
            executable: URL(fileURLWithPath: "/usr/local/bin/claude"),
            arguments: args,
            prompt: prompt)

        XCTAssertFalse(command.contains(secret),
                       "transcript text leaked into the logged command: \(command)")
        XCTAssertFalse(command.contains("Name this call."),
                       "user prompt leaked into the logged command: \(command)")
        // …while the diagnostically useful parts are all still there.
        XCTAssertTrue(command.contains("--resume \(session.uuidString)"))
        XCTAssertTrue(command.contains("/usr/local/bin/claude"))
    }

    /// An empty prompt must not turn into a wildcard that redacts every empty
    /// argument in argv.
    func test_redacted_command_leaves_empty_arguments_alone_when_prompt_is_empty() {
        let command = LLMRunner.redactedCommand(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["-p", "", "--flag"],
            prompt: "")

        XCTAssertEqual(command, "/bin/echo -p '' --flag")
        XCTAssertFalse(command.contains("<prompt:"))
    }

    /// Paths and args with spaces stay unambiguous — the line is read by a
    /// human trying to work out which binary ran.
    func test_redacted_command_quotes_paths_containing_spaces() {
        let command = LLMRunner.redactedCommand(
            executable: URL(fileURLWithPath: "/Users/x/My Tools/claude"),
            arguments: ["--model", "claude sonnet"],
            prompt: "unused")

        XCTAssertEqual(command, "'/Users/x/My Tools/claude' --model 'claude sonnet'")
    }

    /// Extra args the user typed in Settings are metadata, not content, so
    /// they are kept verbatim — a wrong flag is a thing people need to see.
    func test_redacted_command_keeps_user_extra_args() {
        let prompt = "p"
        let command = LLMRunner.redactedCommand(
            executable: URL(fileURLWithPath: "/bin/claude"),
            arguments: LLMTool.claude.arguments(prompt: prompt) + ["--debug", "--permission-mode", "plan"],
            prompt: prompt)

        XCTAssertEqual(command, "/bin/claude -p <prompt:1c> --debug --permission-mode plan")
    }

    // MARK: - stderrTail

    /// Multi-line stderr is folded to one greppable line, and blank lines /
    /// indentation are dropped rather than padding the excerpt out.
    func test_stderr_tail_flattens_newlines_and_drops_blank_lines() {
        let stderr = "warning: deprecated flag\n\n   Error: auth token expired\n"
        XCTAssertEqual(LLMRunner.stderrTail(stderr),
                       "warning: deprecated flag | Error: auth token expired")
    }

    /// Truncation keeps the END. CLIs print the fatal error last, after the
    /// progress chatter, so a head-biased excerpt would reliably capture the
    /// least useful part.
    func test_stderr_tail_keeps_the_tail_when_over_the_limit() {
        let stderr = String(repeating: "n", count: 40) + "FATAL"
        let tail = LLMRunner.stderrTail(stderr, limit: 10)

        XCTAssertEqual(tail, "…nnnnnFATAL")
        XCTAssertEqual(tail.count, 11, "ellipsis plus exactly `limit` characters")
    }

    /// A log line reading `stderr-tail=` with nothing after it is the correct
    /// rendering of "the CLI said nothing" — better than a run of spaces.
    func test_stderr_tail_of_whitespace_only_stderr_is_empty() {
        XCTAssertEqual(LLMRunner.stderrTail("\n \n\t\n"), "")
        XCTAssertEqual(LLMRunner.stderrTail(""), "")
    }

    /// Under the limit, the text is returned whole — no ellipsis noise.
    func test_stderr_tail_under_the_limit_is_untruncated() {
        XCTAssertEqual(LLMRunner.stderrTail("boom", limit: 512), "boom")
    }

    // MARK: - field tags

    /// "The CLI chose" and "we pinned a model" are different diagnoses, so
    /// they must not both render as an empty `model=`.
    func test_model_tag_distinguishes_default_from_pinned() {
        XCTAssertEqual(LLMRunner.modelTag(nil), "(default)")
        XCTAssertEqual(LLMRunner.modelTag(""), "(default)")
        XCTAssertEqual(LLMRunner.modelTag("   "), "(default)")
        XCTAssertEqual(LLMRunner.modelTag("  haiku  "), "haiku")
    }

    /// The session tag has to make a `--resume` chain correlatable across
    /// lines (and with the jsonl filename claude writes) without printing a
    /// full UUID in every line.
    func test_session_tag_renders_each_mode() {
        let id = UUID(uuidString: "DEADBEEF-1234-5678-9ABC-DEF012345678")!
        XCTAssertEqual(LLMRunner.sessionTag(.none), "none")
        XCTAssertEqual(LLMRunner.sessionTag(.new(id)), "new:DEADBEEF")
        XCTAssertEqual(LLMRunner.sessionTag(.resume(id)), "resume:DEADBEEF")
    }

    func test_duration_tag_is_fixed_precision() {
        XCTAssertEqual(LLMRunner.durationTag(0), "0.00")
        XCTAssertEqual(LLMRunner.durationTag(0.0009), "0.00")
        XCTAssertEqual(LLMRunner.durationTag(4.20666), "4.21")
        XCTAssertEqual(LLMRunner.durationTag(301), "301.00")
    }

    // MARK: - feature labels

    /// These `rawValue`s are the grep tokens in the log — a saved predicate
    /// like `eventMessage CONTAINS "feature=live-ai"` breaks silently if one
    /// is renamed, so they are pinned here on purpose.
    func test_feature_log_tokens_are_stable() {
        XCTAssertEqual(LLMFeature.name.rawValue, "name")
        XCTAssertEqual(LLMFeature.summary.rawValue, "summary")
        XCTAssertEqual(LLMFeature.action.rawValue, "action")
        XCTAssertEqual(LLMFeature.liveAI.rawValue, "live-ai")
        XCTAssertEqual(LLMFeature.settingsTest.rawValue, "settings-test")
        XCTAssertEqual(LLMFeature.unspecified.rawValue, "unspecified")
    }

    /// Tokens must be single words: a space would split a `key=value` pair in
    /// the log line and break naive parsing of it.
    func test_feature_log_tokens_have_no_whitespace() {
        for feature in [LLMFeature.name, .summary, .action, .liveAI,
                        .settingsTest, .unspecified] {
            XCTAssertFalse(feature.rawValue.contains(where: { $0.isWhitespace }),
                           "\(feature) has whitespace in its log token")
            XCTAssertFalse(feature.rawValue.isEmpty)
        }
    }
}
