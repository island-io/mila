import XCTest
@testable import Mila

/// `ClaudeSetupTokenParser` reading `claude setup-token`'s output (issue #271).
///
/// The transcripts here are shaped like the real thing: an Ink TUI that emits
/// ANSI escapes, redraws lines in place, hard-wraps to the terminal width, and
/// positions words with cursor moves instead of spaces. Every rule in the
/// parser exists because of one of those, so the fixtures reproduce them rather
/// than testing against tidy text the real CLI never produces.
final class ClaudeSetupTokenParserTests: XCTestCase {

    /// A realistic authorization URL — long enough to wrap at any sane terminal
    /// width, with the query-string punctuation that a naive URL regex trips on.
    private static let authURL =
        "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        + "&response_type=code&redirect_uri=https%3A%2F%2Fconsole.anthropic.com%2Foauth%2Fcode%2Fcallback"
        + "&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference"
        + "&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256"
        + "&state=n1Uv9KpQ7rTfXbZ2"

    private static let token = "sk-ant-oat01-" + String(repeating: "A1b2C3d4", count: 8)

    // MARK: - Sanitizing

    func test_ansi_escapes_and_control_characters_are_stripped() {
        let raw = "\u{1B}[2K\u{1B}[1G\u{1B}[36m· Opening browser to sign in…\u{1B}[39m\u{07}\r\n"
        let clean = ClaudeSetupTokenParser.sanitize(raw)
        XCTAssertFalse(clean.contains("\u{1B}"), "no escape sequences survive")
        XCTAssertFalse(clean.contains("\u{07}"), "no bell")
        XCTAssertTrue(clean.contains("Opening browser to sign in"))
    }

    func test_osc_sequences_are_removed_before_csi() {
        // An OSC payload can contain characters the CSI pattern matches, so
        // order matters: strip OSC first or its terminator is left behind.
        let raw = "\u{1B}]0;claude — setup-token\u{07}\u{1B}[1mReady\u{1B}[0m"
        let clean = ClaudeSetupTokenParser.sanitize(raw)
        XCTAssertEqual(clean, "Ready")
    }

    func test_carriage_returns_become_newlines_so_redrawn_lines_stay_separate() {
        let clean = ClaudeSetupTokenParser.sanitize("Loading.\rLoading..\rLoading...")
        XCTAssertEqual(clean.components(separatedBy: "\n").count, 3)
    }

    // MARK: - Wrapping

    func test_a_url_hard_wrapped_by_the_tui_is_rejoined() {
        let width = 40
        let url = Self.authURL
        // Chop it the way a terminal would: exactly `width` columns per line.
        var wrapped: [String] = []
        var remaining = Substring(url)
        while !remaining.isEmpty {
            let piece = remaining.prefix(width)
            wrapped.append(String(piece))
            remaining = remaining.dropFirst(width)
        }
        XCTAssertGreaterThan(wrapped.count, 3, "fixture really is wrapped")

        let text = "Use the url below to sign in\n" + wrapped.joined(separator: "\n")
        let dewrapped = ClaudeSetupTokenParser.dewrap(text, width: width)
        XCTAssertTrue(dewrapped.contains(url), "the URL is put back together")
    }

    func test_dewrap_leaves_ordinary_short_lines_alone() {
        let text = "one\ntwo\nthree"
        XCTAssertEqual(ClaudeSetupTokenParser.dewrap(text, width: 400), text)
    }

    // MARK: - Marker detection

    /// Ink positions words with cursor escapes rather than spaces, so a line
    /// that reads "Paste code here" on screen can arrive with no spaces at all.
    func test_markers_match_even_when_the_tui_ate_the_spaces() {
        var parser = ClaudeSetupTokenParser()
        let events = parser.consume("Pastecodehere ifprompted >")
        XCTAssertTrue(events.contains(.awaitingCode))
    }

    func test_the_authorization_url_is_detected_and_reported_once() throws {
        var parser = ClaudeSetupTokenParser()
        let first = parser.consume("Browser didn't open? Use the url below (c to copy)\n\(Self.authURL)\n")
        guard case .authorizationURL(let url)? = first.first(where: {
            if case .authorizationURL = $0 { return true } else { return false }
        }) else {
            return XCTFail("expected an authorizationURL event, got \(first)")
        }
        XCTAssertEqual(url.absoluteString, Self.authURL)

        // More output arrives; the URL must not be announced a second time.
        let second = parser.consume("Paste code here if prompted >")
        XCTAssertFalse(second.contains { if case .authorizationURL = $0 { return true } else { return false } })
    }

    /// The URL is handed to `NSWorkspace.open`, so "the subprocess said so" is
    /// not on its own a good enough reason to send a browser somewhere.
    func test_a_url_on_an_unrelated_host_is_not_treated_as_the_authorization_url() {
        var parser = ClaudeSetupTokenParser()
        let events = parser.consume("See https://evil.example.com/authorize?x=1 for details\n")
        XCTAssertFalse(events.contains { if case .authorizationURL = $0 { return true } else { return false } })
    }

    func test_a_lookalike_host_is_refused() {
        XCTAssertFalse(ClaudeSetupTokenParser.isAcceptableAuthorizationURL(
            URL(string: "https://claude.ai.evil.com/oauth")!))
        XCTAssertFalse(ClaudeSetupTokenParser.isAcceptableAuthorizationURL(
            URL(string: "http://claude.ai/oauth")!), "https only")
        XCTAssertTrue(ClaudeSetupTokenParser.isAcceptableAuthorizationURL(
            URL(string: "https://console.anthropic.com/oauth")!), "subdomain on a listed host")
    }

    func test_the_cli_opening_its_own_browser_is_reported() {
        var parser = ClaudeSetupTokenParser()
        XCTAssertTrue(parser.consume("· Opening browser to sign in…\n").contains(.browserOpenedByCLI))
    }

    // MARK: - Token capture

    func test_a_token_is_captured() {
        var parser = ClaudeSetupTokenParser()
        let events = parser.consume("Your token:\n\(Self.token)\n")
        XCTAssertTrue(events.contains(.token(Self.token)))
    }

    /// A pty hands out arbitrary reads, so a token routinely straddles two
    /// chunks. The parser accumulates for exactly this reason.
    func test_a_token_split_across_two_chunks_is_still_captured() {
        var parser = ClaudeSetupTokenParser()
        let half = Self.token.count / 2
        let first = String(Self.token.prefix(half))
        let second = String(Self.token.dropFirst(half))

        XCTAssertTrue(parser.consume("Token: " + first).isEmpty, "no token yet")
        XCTAssertTrue(parser.consume(second + "\n").contains(.token(Self.token)))
    }

    /// The prefix appearing in prose — a help string describing the format —
    /// must not be mistaken for a credential.
    func test_the_bare_prefix_in_prose_is_not_a_token() {
        var parser = ClaudeSetupTokenParser()
        let events = parser.consume("Tokens start with sk-ant- and are issued once.\n")
        XCTAssertFalse(events.contains { if case .token = $0 { return true } else { return false } })
    }

    // MARK: - Redaction

    func test_the_transcript_never_carries_the_token() {
        var parser = ClaudeSetupTokenParser()
        _ = parser.consume("Welcome\n\(Self.authURL)\nYour token:\n\(Self.token)\n")
        let transcript = parser.redactedTranscript
        XCTAssertFalse(transcript.contains(Self.token), "the credential must not survive")
        XCTAssertTrue(transcript.contains("sk-ant-<redacted>"))
        XCTAssertTrue(transcript.contains(Self.authURL), "everything else is preserved")
    }

    /// Redaction runs over the accumulated buffer, not per arriving chunk —
    /// otherwise a split token matches neither half and both halves are copied
    /// into the transcript.
    func test_a_token_split_across_chunks_is_still_redacted() {
        var parser = ClaudeSetupTokenParser()
        let half = Self.token.count / 2
        _ = parser.consume("Token: " + String(Self.token.prefix(half)))
        _ = parser.consume(String(Self.token.dropFirst(half)) + "\n")
        XCTAssertFalse(parser.redactedTranscript.contains(Self.token))
    }

    // MARK: - Rejections

    func test_a_rejected_code_is_reported_with_the_clis_own_words() {
        var parser = ClaudeSetupTokenParser()
        let events = parser.consume("""
            OAuth error: Invalid code. Please make sure the full code was copied
            Press Enter to retry.
            """)
        guard case .codeRejected(let message)? = events.first(where: {
            if case .codeRejected = $0 { return true } else { return false }
        }) else {
            return XCTFail("expected a codeRejected event, got \(events)")
        }
        XCTAssertTrue(message.contains("Invalid code"))
        XCTAssertFalse(message.contains("Press Enter"),
                       "Mila drives the retry — that instruction points at nothing")
    }

    /// The CLI re-prompts rather than exiting, so a second bad paste has to be
    /// visible too. Counted, not remembered as a flag.
    func test_a_second_rejection_is_reported_again() {
        var parser = ClaudeSetupTokenParser()
        let first = parser.consume("OAuth error: Invalid code. One\n")
        XCTAssertEqual(first.filter { if case .codeRejected = $0 { return true } else { return false } }.count, 1)

        let second = parser.consume("OAuth error: Invalid code. Two\n")
        XCTAssertEqual(second.filter { if case .codeRejected = $0 { return true } else { return false } }.count, 1,
                       "only the NEW rejection is re-emitted")
    }

    // MARK: - Full transcript

    /// The whole observed shape at once, with escapes and a spinner redraw, fed
    /// in the awkward chunk boundaries a pty actually produces.
    func test_a_realistic_transcript_produces_the_expected_event_sequence() {
        var parser = ClaudeSetupTokenParser()
        var events: [ClaudeSetupTokenParser.Event] = []
        let chunks = [
            "\u{1B}[2J\u{1B}[HWelcome to Claude Code v2.1.260\r\n\r\n",
            "This will guide you through long-lived (1-year) auth token setup.\r\n\r\n",
            "\u{1B}[36m·\u{1B}[39m Opening browser to sign in…\r",
            "\u{1B}[2K\u{1B}[1GBrowser didn't open? Use the url below to sign in (c to copy)\r\n\r\n",
            Self.authURL + "\r\n\r\n",
            "Paste code here if prompted >"
        ]
        for chunk in chunks { events += parser.consume(chunk) }

        XCTAssertTrue(events.contains(.browserOpenedByCLI))
        XCTAssertTrue(events.contains { if case .authorizationURL = $0 { return true } else { return false } })
        XCTAssertTrue(events.contains(.awaitingCode))
        XCTAssertFalse(events.contains { if case .token = $0 { return true } else { return false } })
    }
}
