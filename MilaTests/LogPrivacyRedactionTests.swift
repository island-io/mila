import XCTest
@testable import Mila

/// Issues #213 and #193 — user content reaching the unified log as **public**
/// values.
///
/// ## What can and cannot be tested here
///
/// There is no way to assert an `OSLog` field's privacy level from a unit
/// test: `privacy: .private` is a compile-time property of the interpolation,
/// and nothing reads it back. Issue #193 says as much. So the ~30 annotated
/// call sites in this change are verifiable **by inspection only**, and this
/// file makes no attempt to pretend otherwise.
///
/// What *is* testable is the part of the fix that is a pure function, and it
/// happens to be the part that was the actual bug: two error types whose
/// `errorDescription` embeds a **child process's output verbatim**. Annotating
/// their call sites would not have been enough — the content is inside the
/// string before any `Logger` sees it — so each grew a `logDescription` twin
/// that the log sites use instead. Those are pure, and pinning them pins the
/// invariant rather than the formatting.
///
/// The other half of the contract matters just as much and is pinned too:
/// `errorDescription` must KEEP the tool's own words. It is what the Settings
/// test panel, the rename sheet and the post-recording banner render, and a
/// blanket redaction there would trade a log leak for an undiagnosable app.
final class LogPrivacyRedactionTests: XCTestCase {

    // MARK: - #193: LLMRunnerError.nonZeroExit

    /// A verbosely-run CLI echoes the composed prompt back on stderr, and the
    /// composed prompt is the meeting transcript. This is the exposure issue
    /// #193 describes, stated as an assertion.
    func test_nonZeroExit_logDescription_never_contains_the_tool_output() {
        let transcript = "Acme is acquiring Globex for $4.2M; announce Friday."
        let stderr = """
            + exec claude -p 'Summarize this call.

            ---
            Transcript:
            \(transcript)'
            error: credit balance too low
            """
        let error = LLMRunnerError.nonZeroExit(code: 1, stderr: stderr)

        let logged = error.logDescription
        XCTAssertFalse(logged.contains(transcript),
                       "transcript leaked into the log message: \(logged)")
        XCTAssertFalse(logged.contains("credit balance too low"),
                       "raw stderr leaked into the log message: \(logged)")
    }

    /// …and what survives is enough to triage: which exit code, and whether
    /// the tool said anything at all. "exit 1, 0 bytes" and "exit 1, 4 KB" are
    /// different bugs.
    func test_nonZeroExit_logDescription_keeps_the_exit_code_and_a_byte_count() {
        let stderr = String(repeating: "x", count: 4096)
        let logged = LLMRunnerError.nonZeroExit(code: 137, stderr: stderr).logDescription

        XCTAssertTrue(logged.contains("137"), logged)
        XCTAssertTrue(logged.contains("4096B"), logged)
    }

    /// The byte count is UTF-8 bytes, not characters — it answers "how much
    /// did the tool emit?", which must not depend on how the bytes decode.
    func test_nonZeroExit_byte_count_is_utf8_not_characters() {
        let stderr = "שגיאה"  // 5 characters, 10 UTF-8 bytes
        let logged = LLMRunnerError.nonZeroExit(code: 2, stderr: stderr).logDescription

        XCTAssertTrue(logged.contains("10B"), logged)
        XCTAssertFalse(logged.contains("5B"), logged)
    }

    /// The other half of the contract. `errorDescription` is what the user
    /// reads on a surface they asked for, and there the CLI's own words are
    /// the entire value — "command not found", "unknown flag". #193 flagged
    /// that fixing the log would change user-visible text; it does not.
    func test_nonZeroExit_errorDescription_still_shows_the_user_the_tool_output() {
        let error = LLMRunnerError.nonZeroExit(code: 1, stderr: "  unknown flag --foo\n")

        XCTAssertEqual(error.errorDescription,
                       "LLM CLI exited with status 1. unknown flag --foo")
    }

    /// Every other case is a sentence Mila composed out of configuration the
    /// user typed. Redacting those would make the log worse for no gain, so
    /// the two descriptions must stay identical.
    func test_cases_without_tool_output_log_exactly_what_the_user_sees() {
        let cases: [LLMRunnerError] = [
            .toolDisabled,
            .executableNotFound("claude"),
            .timedOut(seconds: 90),
            .emptyOutput,
            .cancelled
        ]
        for error in cases {
            XCTAssertEqual(error.logDescription, error.errorDescription,
                           "\(error) should not be redacted — it carries no tool output")
        }
    }

    /// Call sites catch `Error`, not `LLMRunnerError`, so the redaction has to
    /// survive the type being erased — otherwise it is skipped exactly when
    /// it matters. This is the shape `PostRecordingCoordinator`,
    /// `RecordingSummarizer` and `LiveAISession` actually use.
    func test_logMessage_redacts_a_nonZeroExit_thrown_as_a_bare_error() {
        let secret = "We agreed to let Dana go at the end of Q3."
        let thrown: Error = LLMRunnerError.nonZeroExit(code: 1, stderr: secret)

        let logged = LLMRunnerError.logMessage(for: thrown)
        XCTAssertFalse(logged.contains(secret),
                       "content leaked once the concrete type was erased: \(logged)")
        XCTAssertTrue(logged.contains("status 1"), logged)
    }

    /// A non-runner error still gets its readable message — the helper is a
    /// redaction, not a gag. An `OpenAIRequestError` is the realistic case:
    /// the same catch blocks see it, and "Authentication failed (401)" is the
    /// whole diagnostic.
    func test_logMessage_passes_through_other_localized_errors() {
        let thrown: Error = OpenAIRequestError.auth("Incorrect API key provided")

        XCTAssertEqual(LLMRunnerError.logMessage(for: thrown),
                       OpenAIRequestError.auth("Incorrect API key provided").errorDescription)
    }

    // MARK: - #213: SpeakerDiarizer.Error.diarizationFailed

    /// The same shape as `nonZeroExit`, found by sweeping for it: the case is
    /// built from the pyannote subprocess's stderr, and that script prints
    /// `diarize: running on {wav_path}` — a path whose filename Mila derives
    /// from the recording's title. So the "harmless subprocess chatter" is a
    /// meeting name.
    func test_diarizationFailed_logDescription_never_contains_the_subprocess_output() {
        let wavPath = "/Users/x/Recordings/Q3 layoffs — legal review 2026-08-30.wav"
        let stderr = """
            diarize: loading pipeline from /Applications/Mila.app/…/DiarizationModels
            diarize: running on \(wavPath)
            Traceback (most recent call last):
              File "<string>", line 41, in <module>
            RuntimeError: MPS backend out of memory
            """
        let logged = SpeakerDiarizer.Error.diarizationFailed(stderr).logDescription

        XCTAssertFalse(logged.contains(wavPath),
                       "title-derived path leaked into the log message: \(logged)")
        XCTAssertFalse(logged.contains("Q3 layoffs"),
                       "recording title leaked into the log message: \(logged)")
        XCTAssertTrue(logged.contains("\(stderr.utf8.count)B"), logged)
    }

    /// The interpreter path is a value the user typed into Settings, names no
    /// recording, and is the entire diagnostic for this case — so it passes
    /// through unredacted.
    func test_pythonNotFound_is_not_redacted() {
        let error = SpeakerDiarizer.Error.pythonNotFound("/opt/homebrew/bin/python3")

        XCTAssertEqual(error.logDescription, error.errorDescription)
        XCTAssertTrue(error.logDescription.contains("/opt/homebrew/bin/python3"))
    }

    /// Same type-erasure guard as the LLM path: `TranscriptionService` catches
    /// `Error` around both the batch and the re-diarize calls.
    func test_diarizer_logMessage_redacts_through_a_bare_error() {
        let thrown: Error = SpeakerDiarizer.Error.diarizationFailed("running on /x/Board offsite.wav")

        XCTAssertFalse(SpeakerDiarizer.Error.logMessage(for: thrown).contains("Board offsite"),
                       "title leaked once the concrete type was erased")
    }

    /// A cancellation or a decode failure reaches the same catch blocks and
    /// must still read normally.
    func test_diarizer_logMessage_passes_through_other_errors() {
        let thrown: Error = CocoaError(.fileNoSuchFile)

        XCTAssertEqual(SpeakerDiarizer.Error.logMessage(for: thrown),
                       thrown.localizedDescription)
    }
}
