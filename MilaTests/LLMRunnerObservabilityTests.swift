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
    ///
    /// This is the *inline* delivery — the transcript is literally inside the
    /// prompt argument. See
    /// `test_redacted_command_never_contains_referenced_sidecar_paths` for why
    /// the redaction still has to hold once #179 takes the body back out.
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

    /// Issue #179 moves the transcript body out of argv and puts sidecar
    /// **paths** there instead. The tempting conclusion is that the prompt
    /// argument no longer needs redacting; it is wrong, and this test is the
    /// statement of why.
    ///
    /// A recording's filename is derived from its title, and Mila generates
    /// that title from the meeting with an LLM. So `…/Q3 layoffs — legal
    /// review.srt` in a log line leaks the same class of thing the transcript
    /// would, one line at a time, into a store that persists for days and is
    /// readable by anything with the right entitlement. The prompt argument
    /// also still carries the Live-AI summary in this mode.
    ///
    /// What replaces the lost detail is the `delivery=` / `refs=` pair on the
    /// start line, which names extensions and never filenames.
    func test_redacted_command_never_contains_referenced_sidecar_paths() {
        let title = "Q3 layoffs — legal review"
        let dir = "/Users/someone/Recordings"
        let files = TranscriptFiles(subtitles: URL(fileURLWithPath: "\(dir)/\(title).srt"),
                                    plainText: URL(fileURLWithPath: "\(dir)/\(title).txt"),
                                    audio: URL(fileURLWithPath: "\(dir)/\(title).m4a"))
        let prompt = LLMRunner.composedPrompt("File this.",
                                              transcript: "the body",
                                              summary: "We agreed to ship on Friday.",
                                              delivery: .reference(files))
        let args = LLMTool.claude.arguments(prompt: prompt)
        let command = LLMRunner.redactedCommand(
            executable: URL(fileURLWithPath: "/usr/local/bin/claude"),
            arguments: args,
            prompt: prompt)

        XCTAssertEqual(command, "/usr/local/bin/claude -p <prompt:\(prompt.count)c>")
        XCTAssertFalse(command.contains(title),
                       "a recording title leaked into the logged command via its path: \(command)")
        XCTAssertFalse(command.contains(".srt"),
                       "a referenced sidecar path leaked into the logged command: \(command)")
        XCTAssertFalse(command.contains("ship on Friday"),
                       "the summary leaked into the logged command: \(command)")
    }

    /// The tokens that replace what reference delivery took away. Pinned as
    /// literals because they are grep targets in the unified log, exactly like
    /// the `feature=` tokens below.
    func test_delivery_log_tokens_are_stable() {
        XCTAssertEqual(TranscriptDelivery.inline.logToken, "inline")
        XCTAssertEqual(TranscriptDelivery.inline.refsToken, "none")

        let files = TranscriptFiles(subtitles: URL(fileURLWithPath: "/r/a.srt"),
                                    plainText: URL(fileURLWithPath: "/r/a.txt"),
                                    audio: URL(fileURLWithPath: "/r/a.m4a"))
        XCTAssertEqual(TranscriptDelivery.reference(files).logToken, "reference")
        XCTAssertEqual(TranscriptDelivery.reference(files).refsToken, "srt+txt+audio")
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

    /// Extra args are free text from Settings and people put credentials in
    /// them. Flag *names* survive (a wrong flag is a thing people need to
    /// see); every value is reduced to a length.
    func test_redacted_command_redacts_extra_argument_values() {
        let prompt = "p"
        let extraArgs = ["--debug", "--api-key", "sk-ant-secret", "--permission-mode", "plan"]
        let command = LLMRunner.redactedCommand(
            executable: URL(fileURLWithPath: "/bin/claude"),
            arguments: LLMTool.claude.arguments(prompt: prompt) + extraArgs,
            prompt: prompt,
            extraArgsCount: extraArgs.count)

        XCTAssertEqual(command,
                       "/bin/claude -p <prompt:1c> --debug --api-key <value:13c> "
                       + "--permission-mode <value:4c>")
        XCTAssertFalse(command.contains("sk-ant-secret"),
                       "a credential in extra args leaked into the log: \(command)")
    }

    /// The glued `--flag=value` form must split, or the `hasPrefix("-")`
    /// check would wave the whole token through with its payload attached.
    func test_redacted_command_splits_glued_flag_values() {
        let extraArgs = ["--api-key=sk-abc", "--url=https://x.example/v1?token=t"]
        let command = LLMRunner.redactedCommand(
            executable: URL(fileURLWithPath: "/bin/gemini"),
            arguments: extraArgs,
            prompt: "unused",
            extraArgsCount: extraArgs.count)

        XCTAssertEqual(command,
                       "/bin/gemini --api-key=<value:6c> --url=<value:28c>")
        XCTAssertFalse(command.contains("sk-abc"))
        XCTAssertFalse(command.contains("token=t"))
    }

    /// Only the trailing `extraArgsCount` tokens are user input. Mila's own
    /// generated arguments are values Mila chose, and they stay readable —
    /// a wrong `--model` is a common cause of a non-zero exit.
    func test_redacted_command_keeps_mila_generated_arguments_visible() {
        let prompt = "p"
        let session = UUID()
        let extraArgs = ["secret-positional"]
        let command = LLMRunner.redactedCommand(
            executable: URL(fileURLWithPath: "/bin/claude"),
            arguments: LLMTool.claude.arguments(prompt: prompt,
                                                model: "haiku",
                                                session: .new(session)) + extraArgs,
            prompt: prompt,
            extraArgsCount: extraArgs.count)

        XCTAssertEqual(command,
                       "/bin/claude -p <prompt:1c> --model haiku "
                       + "--session-id \(session.uuidString) <value:17c>")
    }

    /// Default `extraArgsCount` of 0 must not redact the tail of a
    /// tool-generated argv — callers that pass no extra args get the full,
    /// readable command.
    func test_redacted_command_with_no_extra_args_redacts_nothing_but_the_prompt() {
        let prompt = "p"
        let command = LLMRunner.redactedCommand(
            executable: URL(fileURLWithPath: "/bin/claude"),
            arguments: LLMTool.claude.arguments(prompt: prompt, model: "sonnet"),
            prompt: prompt)

        XCTAssertEqual(command, "/bin/claude -p <prompt:1c> --model sonnet")
    }

    // MARK: - redactedExtraArg

    func test_redacted_extra_arg_keeps_bare_flags_and_redacts_values() {
        XCTAssertEqual(LLMRunner.redactedExtraArg("--verbose"), "--verbose")
        XCTAssertEqual(LLMRunner.redactedExtraArg("-v"), "-v")
        XCTAssertEqual(LLMRunner.redactedExtraArg("sk-abc"), "<value:6c>")
        XCTAssertEqual(LLMRunner.redactedExtraArg(""), "<value:0c>")
    }

    /// A value containing `=` must not be split more than once, or part of
    /// the payload would survive as a "flag name".
    func test_redacted_extra_arg_splits_on_the_first_equals_only() {
        XCTAssertEqual(LLMRunner.redactedExtraArg("--data=a=b=c"), "--data=<value:5c>")
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
