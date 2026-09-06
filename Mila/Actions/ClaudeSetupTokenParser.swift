import Foundation

/// Reads `claude setup-token`'s output and says what just happened.
///
/// Pure and incremental: feed it whatever bytes arrived, get back the events
/// they completed. Everything interesting about the guided login — did the
/// authorization URL appear, is the CLI waiting for a code, was the code
/// rejected, did a token come back — is decided here, over a `String`, so the
/// whole flow can be tested against recorded transcripts without a pty, a
/// subprocess, or a network.
///
/// ## What the output actually looks like
///
/// `setup-token` is not a line-oriented program. It is an Ink (React-for-the-
/// terminal) TUI, and that shapes every rule below. Captured from the real CLI
/// (v2.1.260) under a pty:
///
/// ```text
/// Welcome to Claude Code v2.1.260
///
/// This will guide you through long-lived (1-year) auth token setup for your
/// Claude account. Claude subscription required.
///
/// · Opening browser to sign in…
///
/// Browser didn't open? Use the url below to sign in (c to copy)
///
/// https://claude.com/cai/oauth/authorize?code=true&client_id=…&state=…
///
/// Hold Shift (Option in iTerm2, Fn in Terminal.app) while selecting to use your
/// terminal's native copy
///
/// Paste code here if prompted >
/// ```
///
/// Three consequences:
///
/// 1. **It is full of escape sequences**, including cursor movement used to
///    redraw a spinner in place. `sanitize` strips them; what survives is text.
/// 2. **It hard-wraps to the terminal width**, and it will happily wrap the
///    authorization URL mid-query-string. Mila asks for a 400-column pty
///    precisely so that doesn't happen (the URL is ~330 characters), but
///    `dewrap` rejoins wrapped lines anyway — the width is a property of a
///    remote program's layout code, not a contract.
/// 3. **Whitespace is not reliable.** Ink positions words with cursor escapes
///    rather than spaces, so a line that reads `Paste code here` on screen can
///    arrive as `Pastecodehere` once the positioning is stripped. Every marker
///    is therefore matched against a whitespace-free, lowercased normalization
///    of the text — never against the literal phrase.
///
/// ## What is NOT known
///
/// The success path could not be observed: completing it requires authorizing
/// in a browser and pasting a real code, which mints a real credential. So the
/// token pattern below is derived from the prefix the shipped binary carries
/// (`sk-ant-oat…`) rather than from a captured success transcript. If a future
/// version stops printing the token, `token` simply never fires — and
/// `ClaudeSetupTokenSession` reports "the CLI finished but Mila didn't find a
/// token" instead of claiming success. That failure is loud on purpose.
struct ClaudeSetupTokenParser {

    /// Something the CLI did that the UI has to react to.
    enum Event: Equatable {
        /// The CLI said it is opening a browser itself. Mila uses this to avoid
        /// opening a *second* tab on the same authorization URL.
        case browserOpenedByCLI
        /// The authorization URL, validated to be on an Anthropic host.
        case authorizationURL(URL)
        /// The CLI is waiting for the code to be pasted.
        case awaitingCode
        /// A submitted code was rejected. The CLI stays alive and re-prompts,
        /// so this is recoverable — the sheet shows the message and lets the
        /// user paste again.
        case codeRejected(String)
        /// A token was found in the output.
        case token(String)
    }

    /// Columns Mila requests for the pty. 400 was verified against the real CLI:
    /// at 80 the authorization URL wraps across five lines, at 400 it prints on
    /// one. Not "very large" — a width the TUI pads to would make every line
    /// enormous — just comfortably past the longest thing it prints.
    static let terminalWidth = 400

    private let width: Int
    private var buffer = ""
    private var emitted: Set<String> = []
    private var rejectionsSeen = 0

    init(terminalWidth: Int = ClaudeSetupTokenParser.terminalWidth) {
        self.width = terminalWidth
    }

    /// Bound on the retained transcript. The CLI redraws a spinner, so output
    /// grows without bound while it waits; keeping a window is what stops a
    /// user who leaves the sheet open from accumulating megabytes. Sized well
    /// past any single screen the TUI draws, so a marker can't be cut in half.
    private static let bufferLimit = 64 * 1024

    /// Everything seen so far, cleaned up and with anything token-shaped
    /// replaced.
    ///
    /// This is the ONLY way the transcript leaves the parser, and the redaction
    /// deliberately happens here — over the accumulated buffer — rather than
    /// per arriving chunk. A pty hands out arbitrary 8 KB reads, so a token can
    /// straddle two of them; redacting each chunk as it arrives would match
    /// neither half and copy the credential into the transcript in two pieces.
    ///
    /// The raw bytes do live in `buffer` while the flow runs — the token has to
    /// be found before it can be redacted, so that is unavoidable. What is
    /// guaranteed is that nothing outside this type ever sees them.
    var redactedTranscript: String {
        Self.redact(Self.dewrap(Self.sanitize(buffer), width: width))
    }

    /// Feed newly-arrived output. Returns the events it completed, in order.
    mutating func consume(_ chunk: String) -> [Event] {
        buffer += chunk
        if buffer.count > Self.bufferLimit {
            buffer = String(buffer.suffix(Self.bufferLimit))
        }
        let text = Self.dewrap(Self.sanitize(buffer), width: width)
        let flat = Self.normalized(text)

        var events: [Event] = []

        if flat.contains("openingbrowser"), emitted.insert("browser").inserted {
            events.append(.browserOpenedByCLI)
        }
        if let url = Self.authorizationURL(in: text), emitted.insert("url").inserted {
            events.append(.authorizationURL(url))
        }
        if flat.contains("pastecodehere"), emitted.insert("await").inserted {
            events.append(.awaitingCode)
        }
        // Rejections repeat: the CLI re-prompts rather than exiting, so the
        // second bad paste has to be visible too. Counted rather than
        // remembered as a flag.
        let rejections = Self.rejectionMessages(in: text)
        if rejections.count > rejectionsSeen {
            events += rejections[rejectionsSeen...].map { Event.codeRejected($0) }
            rejectionsSeen = rejections.count
        }
        if let token = Self.token(in: text), emitted.insert("token").inserted {
            events.append(.token(token))
        }
        return events
    }

    /// Last-chance scan, for use once the child has exited.
    ///
    /// The stream is over, so the buffer is everything the CLI ever printed and
    /// a match at its end can no longer be a half-arrived read. This is what
    /// keeps the boundary rule in `token(in:)` from costing a legitimate
    /// success when the CLI's very last bytes are the token itself, with no
    /// trailing newline.
    ///
    /// Returns nil if a token was already reported, so a caller cannot deliver
    /// the same credential twice.
    mutating func finalToken() -> String? {
        let text = Self.dewrap(Self.sanitize(buffer), width: width)
        guard let token = Self.token(in: text, allowUnterminated: true),
              emitted.insert("token").inserted else { return nil }
        return token
    }

    // MARK: - Text handling

    /// Strip ANSI escape sequences and control characters, and fold carriage
    /// returns into newlines so a redrawn line reads as its own line rather
    /// than being glued to the previous one.
    static func sanitize(_ text: String) -> String {
        var result = text
        for pattern in escapePatterns {
            result = pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "")
        }
        result = result.replacingOccurrences(of: "\r\n", with: "\n")
        result = result.replacingOccurrences(of: "\r", with: "\n")
        // Everything else below space, except tab and newline, is TUI
        // machinery (bells, backspaces) that would otherwise sit inside a
        // token or URL match.
        return String(result.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar.value >= 0x20
        })
    }

    private static let escapePatterns: [NSRegularExpression] = {
        // OSC first: its payload can contain characters the CSI pattern would
        // match, so removing CSI first would leave the OSC terminator behind.
        let patterns = [
            "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)",  // OSC … BEL / ST
            "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",                    // CSI
            "\u{1B}[@-Z\\\\-_]"                                // two-character
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// Rejoin lines the TUI hard-wrapped.
    ///
    /// A wrap is inferred from the shape the wrapper leaves: a line that filled
    /// the terminal exactly, ends in a non-space, and is followed by a line
    /// that starts with a non-space. Prose that happens to fit that pattern
    /// gets joined too, which is harmless — marker matching ignores whitespace
    /// — while a URL split across five lines is put back together, which is the
    /// case that matters.
    static func dewrap(_ text: String, width: Int) -> String {
        guard width > 0 else { return text }
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            if let previous = lines.last,
               previous.count >= width,
               let tail = previous.last, !tail.isWhitespace,
               let head = line.first, !head.isWhitespace {
                lines[lines.count - 1] = previous + line
            } else {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Lowercased, with every whitespace character removed. This is the only
    /// form marker phrases are matched against — see the note about Ink
    /// positioning words with escapes instead of spaces.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    // MARK: - Extraction

    /// Hosts an authorization URL may be on.
    ///
    /// An allowlist rather than "whatever URL appeared", because this URL is
    /// handed to `NSWorkspace.open` — Mila is deciding to send the user's
    /// browser somewhere, and "the subprocess said so" is not a good enough
    /// reason on its own. Matching is on a dot boundary so `claude.ai.evil.com`
    /// is not a match.
    static let authorizationHosts = ["claude.ai", "claude.com", "anthropic.com"]

    static func isAcceptableAuthorizationURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard url.user == nil, url.password == nil else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return authorizationHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static let urlPattern = try? NSRegularExpression(
        pattern: "https://[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]+")

    /// First acceptable `https://…` in the text. "First" rather than "last"
    /// because the authorization URL is printed once, before anything else the
    /// CLI might link to (a docs URL in an error message, say).
    static func authorizationURL(in text: String) -> URL? {
        guard let urlPattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in urlPattern.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            // Trailing punctuation belongs to the sentence, not the URL.
            let candidate = String(text[matchRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,);:'\""))
            guard let url = URL(string: candidate),
                  isAcceptableAuthorizationURL(url) else { continue }
            return url
        }
        return nil
    }

    /// Shape of the credential `setup-token` mints.
    ///
    /// Anchored on `sk-ant-`, which the shipped binary carries as the prefix
    /// family for its key types (`sk-ant-oat…` is the OAuth one). The length
    /// floor keeps the prefix appearing in prose — a help string, an error
    /// message naming the format — from being mistaken for a credential.
    private static let tokenPattern = try? NSRegularExpression(
        pattern: "sk-ant-[A-Za-z0-9_-]{16,}")

    /// The first token in `text`, or nil.
    ///
    /// **A match that runs to the very end of the buffer is refused** unless
    /// `allowUnterminated` is set, and that rule is the whole point of this
    /// function. A pty hands out arbitrary reads, so a chunk boundary can fall
    /// in the middle of a token — and because a *prefix* of a token is itself
    /// token-shaped (`sk-ant-` plus at least 16 more characters), the naive
    /// match happily returns the half that has arrived. That is the worst
    /// possible outcome: the flow reports success and stores a truncated
    /// credential which fails on first use, far from here.
    ///
    /// The match is greedy, so an end position *before* `endIndex` proves the
    /// next character cannot be part of the token — the value is complete. Any
    /// real token is followed by a newline, so this costs at most one more read
    /// before it fires.
    ///
    /// `allowUnterminated` exists for exactly one caller: the last-chance scan
    /// once the child has exited (`finalToken`). At EOF the buffer is complete,
    /// so a match at the end can no longer be a partial read.
    static func token(in text: String, allowUnterminated: Bool = false) -> String? {
        guard let tokenPattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in tokenPattern.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            if matchRange.upperBound == text.endIndex && !allowUnterminated { continue }
            return String(text[matchRange])
        }
        return nil
    }

    /// Replace anything token-shaped with a description of it.
    ///
    /// Everything that shows or logs a transcript goes through this. The
    /// subprocess output *is* where the credential appears, so "don't log the
    /// token" cannot be a discipline applied at each log site — it has to be a
    /// property of the only string those sites are given. See
    /// `ClaudeSetupTokenSession.redactedTranscript`.
    static func redact(_ text: String) -> String {
        guard let tokenPattern else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return tokenPattern.stringByReplacingMatches(in: text,
                                                     range: range,
                                                     withTemplate: "sk-ant-<redacted>")
    }

    /// Rejected-code messages, in order.
    ///
    /// Observed shape, by pasting a deliberately invalid code:
    ///
    ///     OAuth error: Invalid code. Please make sure the full code was copied
    ///     Press Enter to retry.
    ///
    /// The message is taken from the sanitized (not normalized) text so the
    /// user sees the CLI's own words with their spaces intact; the *detection*
    /// still goes through the normalized form, because that is the only
    /// whitespace-independent way to find the marker.
    static func rejectionMessages(in text: String) -> [String] {
        let flat = normalized(text)
        guard flat.contains("oautherror") || flat.contains("invalidcode") else { return [] }
        var messages: [String] = []
        for line in text.components(separatedBy: "\n") {
            let normalizedLine = normalized(line)
            guard normalizedLine.contains("oautherror") || normalizedLine.contains("invalidcode") else {
                continue
            }
            // Drop the "Press Enter to retry." tail: Mila drives the retry, so
            // telling the user to press Enter points at a keyboard that isn't
            // attached to anything they can see.
            var message = line
            if let cut = message.range(of: "Press Enter", options: .caseInsensitive) {
                message = String(message[..<cut.lowerBound])
            }
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { messages.append(trimmed) }
        }
        return messages
    }
}
