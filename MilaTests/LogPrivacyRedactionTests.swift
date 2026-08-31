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
/// happens to be the part that was the actual bug: four error types whose
/// `errorDescription` embeds **output Mila did not write** — a child process's
/// stderr (`LLMRunnerError.nonZeroExit`, `SpeakerDiarizer.Error`), a remote
/// endpoint's response body (`OpenAIRequestError`,
/// `RemoteWhisperEngine.RemoteError`), or Cocoa's own quoted-path message
/// (`MilaConfig.LoadError`). Annotating their call sites would not have been
/// enough — the content is inside the string before any `Logger` sees it — so
/// each grew a `logDescription` twin that the log sites use instead. Those are
/// pure, and pinning them pins the invariant rather than the formatting.
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

    /// An error the helper has no special knowledge of still gets its readable
    /// message — the helper is a redaction of the types that are known to
    /// carry someone else's bytes, not a gag on every error. A transport
    /// failure ("The Internet connection appears to be offline") is the whole
    /// diagnostic and names nothing.
    func test_logMessage_passes_through_an_unrelated_error() {
        let thrown: Error = CocoaError(.fileNoSuchFile)

        XCTAssertEqual(LLMRunnerError.logMessage(for: thrown),
                       thrown.localizedDescription)
    }

    // MARK: - #193: OpenAIRequestError (the HTTP twin of nonZeroExit)
    //
    // This case previously read "a non-runner error passes through", and that
    // assertion was itself the bug: `OpenAIRequestError` is not a bystander
    // type, it is the second error whose `errorDescription` embeds bytes Mila
    // did not write. `LLMRunner.run`'s `.openaiCompatible` branch rethrows it
    // unchanged, so every log site that goes through `logMessage(for:)` —
    // `PostRecordingCoordinator`, `RecordingSummarizer`, `LiveAISession`,
    // `logSetupFailure`, `logLaunchFailure`, `logHTTPFailure` — published it.
    // (Found by CodeRabbit on this PR.)

    /// The endpoint's own response body reaches `errorDescription` through
    /// `.auth`/`.notFound`/`.server`. A real OpenAI 401 quotes a fragment of
    /// the API key, so the log field was getting a piece of a credential.
    func test_openAIRequestError_logDescription_never_contains_the_server_message() {
        let serverMessage = "Incorrect API key provided: sk-proj-9aBcDeF***XYZ. "
            + "You can find your API key at https://platform.openai.com/account/api-keys."
        let error = OpenAIRequestError.auth(serverMessage)

        let logged = error.logDescription
        XCTAssertFalse(logged.contains("sk-proj-9aBcDeF"),
                       "API key fragment leaked into the log message: \(logged)")
        XCTAssertFalse(logged.contains(serverMessage),
                       "raw server message leaked into the log message: \(logged)")
        // …and what survives is the part that triages: which status.
        XCTAssertTrue(logged.contains("401"), logged)
    }

    /// `.server` carries an arbitrary upstream body — a proxy answering 502
    /// with the payload it was given can put transcript text there.
    func test_openAIRequestError_logDescription_keeps_the_status_and_drops_the_body() {
        let error = OpenAIRequestError.server(status: 502,
                                              message: "upstream rejected: Acme is acquiring Globex")

        let logged = error.logDescription
        XCTAssertTrue(logged.contains("502"), logged)
        XCTAssertFalse(logged.contains("Acme is acquiring Globex"),
                       "upstream body leaked into the log message: \(logged)")
    }

    /// `.invalidEndpoint` is the sharper half: `runOpenAICompatible`
    /// deliberately logs `host=` and never the full URL, because a user's
    /// endpoint can carry a token in its query string — and this case handed
    /// the whole URL back through the failure field, on the one path where the
    /// URL is malformed enough that there was no host to log instead.
    func test_openAIRequestError_logDescription_never_contains_the_configured_endpoint() {
        let baseURL = "https://llm.acme-internal.example/v1?access_token=s3cr3t"
        let error = OpenAIRequestError.invalidEndpoint(baseURL)

        let logged = error.logDescription
        XCTAssertFalse(logged.contains("s3cr3t"),
                       "endpoint token leaked into the log message: \(logged)")
        XCTAssertFalse(logged.contains("acme-internal"),
                       "configured endpoint leaked into the log message: \(logged)")
    }

    /// The other half of the contract, as for `nonZeroExit`: the Settings → AI
    /// Provider test panel and the post-recording banner keep the server's own
    /// words, because that is the only thing that turns "the LLM failed" into
    /// something the user can act on.
    func test_openAIRequestError_errorDescription_still_shows_the_user_the_server_message() {
        XCTAssertEqual(OpenAIRequestError.auth("Incorrect API key provided").errorDescription,
                       "Authentication failed (401). Incorrect API key provided")

        let shown = OpenAIRequestError.invalidEndpoint("https://x y/v1").errorDescription ?? ""
        XCTAssertTrue(shown.contains("https://x y/v1"),
                      "the user must still see which URL was rejected: \(shown)")
    }

    /// `.emptyOutput` carries nothing of anyone's, so the two descriptions
    /// must stay identical — redacting it would be pure loss.
    func test_openAIRequestError_emptyOutput_is_not_redacted() {
        XCTAssertEqual(OpenAIRequestError.emptyOutput.logDescription,
                       OpenAIRequestError.emptyOutput.errorDescription)
    }

    /// The shape the catch blocks actually see: `run` rethrows the typed error
    /// into a `catch { }` that only knows `Error`.
    func test_logMessage_redacts_an_openAIRequestError_thrown_as_a_bare_error() {
        let secret = "sk-proj-9aBcDeF***XYZ"
        let thrown: Error = OpenAIRequestError.auth("Incorrect API key provided: \(secret)")

        let logged = LLMRunnerError.logMessage(for: thrown)
        XCTAssertFalse(logged.contains(secret),
                       "credential leaked once the concrete type was erased: \(logged)")
        XCTAssertTrue(logged.contains("401"), logged)
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
    ///
    /// CodeRabbit asked for this one to be redacted on PR #218. Deliberately
    /// not done, and this assertion is the record of that: the value is
    /// configuration, not content — no title, no transcript, and not the
    /// recordings folder — and the analogous CLI path is already logged
    /// `.public` as `exe=` by design (see `LLMRunner.logRunStart`). "Python not
    /// found at `<private>`" is the over-redaction
    /// `bugbot-rules/no-user-content-in-logs.md` warns about: it removes the
    /// only fact the line exists to report.
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

    /// The decode failure that reaches the same catch blocks. `diarize` sends
    /// every non-WAV recording through `AudioCompressor.decodeToTempWAV`, so an
    /// unreadable `.m4a` in the user-chosen recordings folder surfaces here as
    /// a bare Cocoa file error — and Cocoa's sentence for that names the file
    /// and its folder. This assertion fails against the previous
    /// `localizedDescription` fallback, which published it.
    func test_diarizer_logMessage_withholds_a_bare_file_error() {
        let thrown: Error = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadNoSuchFileError,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The file “Q3 board offsite.m4a” couldn’t be opened because "
                    + "there is no such file.",
                NSFilePathErrorKey: "/Users/x/Audio Notes/Q3 board offsite.m4a"
            ]
        )

        let logged = SpeakerDiarizer.Error.logMessage(for: thrown)

        XCTAssertFalse(logged.contains("Q3 board offsite"),
                       "the recording title reached a public log field")
        XCTAssertFalse(logged.contains("Audio Notes"),
                       "the user-chosen recordings folder reached a public log field")
        XCTAssertEqual(logged, "unexpected error [\(NSCocoaErrorDomain) \(NSFileReadNoSuchFileError)]",
                       "domain + code should survive so the failure stays diagnosable")
    }

    /// Cancellation is the common non-error arrival at that same fallback, and
    /// it must still read as itself rather than as a bare domain/code pair.
    func test_diarizer_logMessage_names_cancellation() {
        XCTAssertEqual(SpeakerDiarizer.Error.logMessage(for: CancellationError()),
                       "diarization cancelled")
    }

    // MARK: - #213: RemoteWhisperEngine.RemoteError.http
    //
    // The remote transcription path is the third instance of the same shape,
    // found by sweeping the files this PR already touched:
    // `RemoteError.http`'s `errorDescription` runs the endpoint's response
    // body through `shortMessage(from:)`, which falls back to a 200-character
    // slice of the raw body. `TranscriptionService.transcribeOnceSegments`
    // logged that `.public` — and its own comment notes the line "repeats on
    // every utterance for the whole recording".

    /// A real OpenAI 401 body quotes a fragment of the API key, and
    /// `shortMessage` lifts exactly that field out of the JSON.
    func test_remoteWhisperError_logDescription_never_contains_the_server_body() {
        let body = """
            {"error":{"message":"Incorrect API key provided: sk-proj-9aBcDeF***XYZ. \
            You can find your API key at https://platform.openai.com/account/api-keys.",\
            "type":"invalid_request_error"}}
            """
        let error = RemoteWhisperEngine.RemoteError.http(status: 401, body: body)

        // Precondition: the leak is real — the user-facing description does
        // carry the key fragment, which is why annotating the call site could
        // never have fixed this.
        let shown = error.errorDescription ?? ""
        XCTAssertTrue(shown.contains("sk-proj-9aBcDeF"),
                      "expected errorDescription to carry the server message: \(shown)")

        let logged = error.logDescription
        XCTAssertFalse(logged.contains("sk-proj-9aBcDeF"),
                       "API key fragment leaked into the log message: \(logged)")
        XCTAssertFalse(logged.contains("Incorrect API key provided"),
                       "server body leaked into the log message: \(logged)")
        // Status and volume survive: "401 with 0 bytes" and "401 with 300
        // bytes" are different bugs.
        XCTAssertTrue(logged.contains("401"), logged)
        XCTAssertTrue(logged.contains("\(body.utf8.count)B"), logged)
    }

    /// A proxy that answers with the payload it was handed puts transcript
    /// text in the body — the same exposure as a CLI echoing its prompt.
    func test_remoteWhisperError_logDescription_drops_an_echoed_transcript() {
        let transcript = "We agreed to let Dana go at the end of Q3."
        let error = RemoteWhisperEngine.RemoteError.http(
            status: 502,
            body: "Bad gateway. Upstream request was: \(transcript)")

        let logged = error.logDescription
        XCTAssertFalse(logged.contains(transcript),
                       "transcript leaked into the log message: \(logged)")
        XCTAssertTrue(logged.contains("502"), logged)
    }

    /// Every other case is a sentence Mila wrote, so the two descriptions must
    /// stay identical — redacting them would make a misconfigured endpoint
    /// undiagnosable for no gain.
    func test_remoteWhisperError_cases_without_a_server_body_are_not_redacted() {
        let cases: [RemoteWhisperEngine.RemoteError] = [
            .notConfigured, .noAudioCaptured, .badResponse, .emptyResult
        ]
        for error in cases {
            XCTAssertEqual(error.logDescription, error.errorDescription,
                           "\(error) should not be redacted — it carries no server output")
        }
    }

    /// The shape `TranscriptionService` uses: the live path catches `Error`.
    func test_remote_logMessage_redacts_through_a_bare_error() {
        let thrown: Error = RemoteWhisperEngine.RemoteError.http(
            status: 401, body: "Incorrect API key provided: sk-proj-XYZ")

        let logged = RemoteWhisperEngine.RemoteError.logMessage(for: thrown)
        XCTAssertFalse(logged.contains("sk-proj-XYZ"),
                       "credential leaked once the concrete type was erased: \(logged)")
        XCTAssertTrue(logged.contains("401"), logged)
    }

    /// …and a transport failure still reads normally.
    func test_remote_logMessage_passes_through_other_errors() {
        let thrown: Error = CocoaError(.fileNoSuchFile)

        XCTAssertEqual(RemoteWhisperEngine.RemoteError.logMessage(for: thrown),
                       thrown.localizedDescription)
    }

    // MARK: - #213: MilaConfig.LoadError
    //
    // The success/failure asymmetry, in the form Bugbot flagged on
    // `WAVHeaderRepair`: `MilaConfigImporter.handleOpen` logs the staged
    // filename `.private` — a `.milaconfig` handed round a team is commonly
    // named for the org it configures — and then its own `catch` published
    // that name straight back through `String(describing: error)`.

    /// `LoadError.unreadable` wraps `Data(contentsOf:).localizedDescription`
    /// verbatim, and Cocoa quotes the filename (and its folder) in there.
    func test_configLoadError_logDescription_never_contains_the_quoted_filename() {
        // The shape Cocoa produces for a file the user double-clicked.
        let cocoaMessage = "The file “Acme Corp — ASR rollout.milaconfig” couldn’t be "
            + "opened because there is no such file."
        let error = MilaConfig.LoadError.unreadable(cocoaMessage)

        let logged = error.logDescription
        XCTAssertFalse(logged.contains("Acme Corp"),
                       "config filename leaked into the log message: \(logged)")
        XCTAssertFalse(logged.contains(cocoaMessage),
                       "raw Cocoa message leaked into the log message: \(logged)")
        XCTAssertEqual(MilaConfig.LoadError.logMessage(for: error), logged)
    }

    /// `.malformed` wraps `JSONDecoder`'s message, which quotes coding keys
    /// and — on a type mismatch — the offending value out of the config.
    func test_configLoadError_malformed_logDescription_never_contains_the_decoder_detail() {
        let detail = "Expected to decode String but found a number instead, "
            + "at CodingKeys(stringValue: \"baseURL\"): https://llm.acme-internal.example/v1"
        let logged = MilaConfig.LoadError.malformed(detail).logDescription

        XCTAssertFalse(logged.contains("acme-internal"),
                       "decoder detail leaked into the log message: \(logged)")
    }

    /// The opposite case, kept public on purpose: two integers Mila composed
    /// itself, which are the entire diagnostic and name nothing.
    func test_configLoadError_unsupportedVersion_is_not_redacted() {
        let error = MilaConfig.LoadError.unsupportedVersion(found: 4, supported: 1)

        XCTAssertEqual(error.logDescription, error.errorDescription)
        XCTAssertTrue(error.logDescription.contains("v4"), error.logDescription)
    }

    /// The user-facing half is unchanged: the confirmation sheet still tells
    /// the user which file it couldn't read.
    func test_configLoadError_errorDescription_still_names_the_file_for_the_user() {
        let cocoaMessage = "The file “Acme Corp — ASR rollout.milaconfig” couldn’t be "
            + "opened because there is no such file."
        let shown = MilaConfig.LoadError.unreadable(cocoaMessage).errorDescription ?? ""

        XCTAssertTrue(shown.contains("Acme Corp"),
                      "the sheet must still tell the user which file failed: \(shown)")
    }

    /// Unlike the LLM and diarizer helpers, this fallback must NOT pass an
    /// unknown error through: `load(from:)` only ever throws `LoadError`, so
    /// anything else here came from the surrounding file-open path — which is
    /// exactly the shape that quotes the user's path.
    func test_configLoadError_logMessage_does_not_pass_through_an_unexpected_file_error() {
        let thrown: Error = CocoaError(.fileNoSuchFile)
        let logged = MilaConfig.LoadError.logMessage(for: thrown)

        XCTAssertNotEqual(logged, thrown.localizedDescription,
                          "an unexpected file error was passed through verbatim: \(logged)")
        let ns = thrown as NSError
        XCTAssertTrue(logged.contains(ns.domain), logged)
        XCTAssertTrue(logged.contains("\(ns.code)"), logged)
    }
}
