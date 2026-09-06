import XCTest
@testable import Mila

/// A `claude setup-token` stand-in that replays a scripted transcript through
/// the same three callbacks the real pty transport uses.
///
/// This is the seam that makes the guided login testable at all: the real
/// transport needs a pseudo-terminal and a real CLI, and running the real
/// `setup-token` mints a real credential and opens a real browser.
final class FakeInteractiveProcess: ClaudeInteractiveProcess {
    var onOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    private(set) var didStart = false
    private(set) var didTerminate = false
    private(set) var written: [String] = []
    /// Set to make `start()` throw, standing in for a missing or broken binary.
    var startError: Error?

    func start() throws {
        if let startError { throw startError }
        didStart = true
    }

    func write(_ text: String) { written.append(text) }
    func terminate() { didTerminate = true }

    // Driving helpers, used by the tests.
    func emit(_ chunk: String) { onOutput?(chunk) }
    func exit(_ status: Int32) { onExit?(status) }
}

/// The state machine between the parser and the pty (issue #271): idle →
/// installing → awaitingCode → verifying → ready, and every way out of it.
@MainActor
final class ClaudeSetupTokenSessionTests: XCTestCase {

    private static let authURL =
        "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a&state=n1Uv9KpQ"
    private static let token = "sk-ant-oat01-" + String(repeating: "A1b2C3d4", count: 8)

    /// Let queued main-actor work (the `Task { @MainActor … }` hops in
    /// `ingest`/`childExited`) run before asserting.
    private func settle(_ turns: Int = 20) async {
        for _ in 0..<turns { await Task.yield() }
    }

    /// Poll until `predicate` holds or the bound elapses. Used only for the
    /// timeout tests, where the thing under test is a real `Task.sleep`.
    private func wait(upTo seconds: TimeInterval,
                      for predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func makeSession(
        timeouts: ClaudeSetupTokenSession.Timeouts = .production
    ) -> (ClaudeSetupTokenSession, FakeInteractiveProcess) {
        let fake = FakeInteractiveProcess()
        let session = ClaudeSetupTokenSession(timeouts: timeouts) { fake }
        return (session, fake)
    }

    // MARK: - Happy path

    func test_the_full_flow_reaches_ready_and_hands_back_the_token() async {
        let (session, fake) = makeSession()
        var opened: [URL] = []
        var captured: [String] = []
        session.onOpenURL = { opened.append($0) }
        session.onToken = { captured.append($0) }

        session.start()
        XCTAssertTrue(fake.didStart)
        XCTAssertEqual(session.state, .signingIn)

        fake.emit("Browser didn't open? Use the url below\n\(Self.authURL)\n")
        await settle()
        XCTAssertEqual(session.state, .awaitingCode(URL(string: Self.authURL)!))
        XCTAssertEqual(opened.map(\.absoluteString), [Self.authURL],
                       "the CLI did not report opening a browser, so Mila opens one")

        session.submit(code: "  the-pasted-code  ")
        XCTAssertEqual(session.state, .verifying)
        XCTAssertEqual(fake.written, ["the-pasted-code\n"],
                       "trimmed, and newline-terminated so the pty submits the line")

        fake.emit("\nSuccess! Your token:\n\(Self.token)\n")
        await settle()
        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(captured, [Self.token])
        XCTAssertTrue(fake.didTerminate, "the child is released once the token is captured")
    }

    /// The CLI opens the browser itself. Mila opening the same URL again gives
    /// the user two tabs of one OAuth request.
    func test_mila_does_not_open_a_second_tab_when_the_cli_opened_one() async {
        let (session, fake) = makeSession()
        var opened: [URL] = []
        session.onOpenURL = { opened.append($0) }

        session.start()
        fake.emit("· Opening browser to sign in…\n\(Self.authURL)\n")
        await settle()

        XCTAssertTrue(opened.isEmpty, "no second browser tab")
        XCTAssertEqual(session.state, .awaitingCode(URL(string: Self.authURL)!))
    }

    // MARK: - Rejection

    func test_a_rejected_code_returns_to_awaiting_and_keeps_the_child_alive() async {
        let (session, fake) = makeSession()
        session.start()
        fake.emit("\(Self.authURL)\nPaste code here >")
        await settle()

        session.submit(code: "wrong")
        XCTAssertEqual(session.state, .verifying)

        fake.emit("\nOAuth error: Invalid code. Please make sure the full code was copied\nPress Enter to retry.\n")
        await settle()

        XCTAssertEqual(session.state, .awaitingCode(URL(string: Self.authURL)!),
                       "recoverable — the CLI re-prompts rather than exiting")
        XCTAssertEqual(session.lastRejection?.contains("Invalid code"), true)
        XCTAssertFalse(fake.didTerminate, "the child must stay alive for the retry")

        // The retry succeeds.
        session.submit(code: "right")
        XCTAssertNil(session.lastRejection, "cleared when a new code is submitted")
        fake.emit("\nYour token:\n\(Self.token)\n")
        await settle()
        XCTAssertEqual(session.state, .ready)
    }

    // MARK: - Failure paths

    /// Exit 0 with nothing token-shaped printed is the scenario the parser's
    /// doc comment warns about. Claiming success would leave a user "signed in"
    /// with no credential, so it is a loud failure.
    func test_exit_zero_without_a_token_is_a_failure_not_a_success() async {
        let (session, fake) = makeSession()
        var captured: [String] = []
        session.onToken = { captured.append($0) }

        session.start()
        fake.emit("\(Self.authURL)\n")
        await settle()
        fake.exit(0)
        await settle()

        guard case .failed(let reason) = session.state else {
            return XCTFail("expected failure, got \(session.state)")
        }
        XCTAssertTrue(reason.contains("didn't print a token"))
        XCTAssertTrue(captured.isEmpty)
    }

    /// A token printed as the CLI's very last bytes, with no trailing newline,
    /// is held back while the stream is live (it could be half a read) and
    /// taken once the child exits. Without the end-of-stream scan this exact
    /// run would be reported as "finished but printed no token".
    func test_a_token_in_the_final_bytes_is_captured_when_the_child_exits() async {
        let (session, fake) = makeSession()
        var captured: [String] = []
        session.onToken = { captured.append($0) }

        session.start()
        fake.emit("\(Self.authURL)\n")
        await settle()
        session.submit(code: "the-code")

        fake.emit("\nYour token: \(Self.token)")   // no trailing newline
        await settle()
        XCTAssertEqual(session.state, .verifying, "held back while more bytes could arrive")

        fake.exit(0)
        await settle()

        XCTAssertEqual(session.state, .ready)
        XCTAssertEqual(captured, [Self.token], "the whole token, exactly once")
    }

    func test_a_nonzero_exit_fails_with_the_status() async {
        let (session, fake) = makeSession()
        session.start()
        fake.exit(3)
        await settle()

        guard case .failed(let reason) = session.state else {
            return XCTFail("expected failure, got \(session.state)")
        }
        XCTAssertTrue(reason.contains("3"))
    }

    func test_a_binary_that_cannot_be_launched_fails_immediately() async {
        let fake = FakeInteractiveProcess()
        fake.startError = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
        let session = ClaudeSetupTokenSession { fake }

        session.start()
        await settle()
        guard case .failed = session.state else {
            return XCTFail("expected failure, got \(session.state)")
        }
    }

    /// The bound that stops a CLI hanging at startup from leaving a spinner up
    /// forever. Driven with a millisecond timeout via the injectable seam.
    func test_the_url_timeout_fails_the_flow() async {
        let (session, fake) = makeSession(
            timeouts: .init(url: 0.05, authorization: 60, verify: 60))
        session.start()

        await wait(upTo: 3) { if case .failed = session.state { return true }; return false }
        guard case .failed(let reason) = session.state else {
            return XCTFail("expected a timeout failure, got \(session.state)")
        }
        XCTAssertTrue(reason.contains("sign-in link"))
        XCTAssertTrue(fake.didTerminate, "a timed-out child is released")
    }

    func test_the_verify_timeout_fails_the_flow() async {
        let (session, fake) = makeSession(
            timeouts: .init(url: 60, authorization: 60, verify: 0.05))
        session.start()
        fake.emit("\(Self.authURL)\n")
        await settle()
        session.submit(code: "some-code")

        await wait(upTo: 3) { if case .failed = session.state { return true }; return false }
        guard case .failed(let reason) = session.state else {
            return XCTFail("expected a timeout failure, got \(session.state)")
        }
        XCTAssertTrue(reason.contains("after the code was submitted"))
    }

    /// Deadlines are per phase, not cumulative: arriving at the next step buys
    /// more time. A short URL bound must not fire once the URL has appeared.
    func test_reaching_the_next_phase_cancels_the_previous_deadline() async {
        let (session, fake) = makeSession(
            timeouts: .init(url: 0.05, authorization: 60, verify: 60))
        session.start()
        fake.emit("\(Self.authURL)\n")
        await settle()
        XCTAssertEqual(session.state, .awaitingCode(URL(string: Self.authURL)!))

        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(session.state, .awaitingCode(URL(string: Self.authURL)!),
                       "the URL deadline was disarmed when the URL arrived")
    }

    // MARK: - Cancellation

    func test_cancelling_releases_the_child_and_returns_to_idle() async {
        let (session, fake) = makeSession()
        session.start()
        fake.emit("\(Self.authURL)\n")
        await settle()

        session.cancel()
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(fake.didTerminate)

        // A late exit from the child it already gave up on must not resurrect a
        // failure over the top of the idle state.
        fake.exit(1)
        await settle()
        XCTAssertEqual(session.state, .idle)
    }

    // MARK: - The login child runs without a credential

    /// `setup-token` mints a credential; it must not be handed the one it is
    /// about to replace. Every other invocation of the managed binary WANTS the
    /// token, so this is a deliberate exception, and it is the one place a
    /// re-login could silently return the old credential instead of a new one.
    func test_the_login_child_never_inherits_an_oauth_token() {
        let binary = ClaudeManagedInstall.binaryURL()
        let env = ClaudeSetupTokenSession.loginEnvironment(
            binary: binary,
            base: ["PATH": "/usr/bin",
                   ClaudeManagedInstall.oauthTokenEnvironmentKey: "sk-ant-oat-stale"])

        XCTAssertNil(env[ClaudeManagedInstall.oauthTokenEnvironmentKey],
                     "a sign-in must start from no credential at all")
        XCTAssertNotNil(env["PATH"], "the rest of the environment is still built normally")
    }

    // MARK: - The token never reaches a log or a UI string

    func test_the_transcript_and_every_log_token_are_free_of_the_credential() async {
        let (session, fake) = makeSession()
        session.start()
        fake.emit("\(Self.authURL)\nYour token:\n\(Self.token)\n")
        await settle()

        XCTAssertFalse(session.redactedTranscript.contains(Self.token),
                       "the only transcript that leaves the session is redacted")

        // `logToken` is what actually reaches os.Logger. No case may carry a
        // payload — not the URL (it has a live OAuth `state`), not the failure
        // reason (it can quote the CLI).
        let states: [ClaudeSetupState] = [
            .idle,
            .installing(progress: 0.5),
            .signingIn,
            .awaitingCode(URL(string: Self.authURL)!),
            .verifying,
            .ready,
            .failed("boom \(Self.token)")
        ]
        for state in states {
            XCTAssertFalse(state.logToken.contains(Self.token))
            XCTAssertFalse(state.logToken.contains("claude.com"))
            XCTAssertFalse(state.logToken.contains("boom"))
        }
    }

    /// One chunk can complete several events, and a terminal one must end the
    /// flow there. Before this was pinned, a chunk carrying BOTH a fatal
    /// rejection and something token-shaped ran the token event afterwards —
    /// turning a reported failure into `.ready` and handing back a credential
    /// from a run that had just been called broken.
    func test_a_terminal_event_stops_the_rest_of_the_same_chunk() async {
        let (session, fake) = makeSession()
        var captured: [String] = []
        session.onToken = { captured.append($0) }

        session.start()
        // No authorization URL has appeared, so the rejection is fatal — and
        // the very same chunk also contains a token-shaped string.
        fake.emit("OAuth error: Invalid code. Leftover: \(Self.token)\n")
        await settle()

        guard case .failed = session.state else {
            return XCTFail("a fatal rejection must stay failed, got \(session.state)")
        }
        XCTAssertTrue(captured.isEmpty,
                      "no credential may be handed back from a failed run")
    }

    /// A failure message is rendered in the UI, so a token echoed by the CLI
    /// into an error must be redacted before it becomes one.
    func test_a_failure_message_built_from_cli_text_is_redacted() async {
        let (session, fake) = makeSession()
        session.start()
        // A rejection before any URL is a hard failure, and it carries the
        // CLI's own words into `.failed`.
        fake.emit("OAuth error: Invalid code near \(Self.token)\n")
        await settle()

        guard case .failed(let reason) = session.state else {
            return XCTFail("expected failure, got \(session.state)")
        }
        XCTAssertFalse(reason.contains(Self.token))
        XCTAssertTrue(reason.contains("sk-ant-<redacted>"))
    }
}
