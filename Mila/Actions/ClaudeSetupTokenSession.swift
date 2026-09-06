import Foundation
import os

private let setupLog = os.Logger(subsystem: "io.island.whisper.IslandWhisper",
                                 category: "ClaudeSetup")

/// A running child process Mila is talking to interactively.
///
/// The seam exists because the real thing needs a pseudo-terminal, and a unit
/// test must not need one. `FakeInteractiveProcess` in the tests replays a
/// recorded transcript through the same three callbacks, so the state machine
/// that reacts to them is exercised for real.
///
/// Callbacks may arrive on any thread; `ClaudeSetupTokenSession` hops to the
/// main actor before touching state.
protocol ClaudeInteractiveProcess: AnyObject {
    /// Called with each chunk of output as it arrives. Chunks are arbitrary —
    /// they split mid-line and mid-escape-sequence — which is why the parser
    /// accumulates rather than matching per chunk.
    var onOutput: ((String) -> Void)? { get set }
    /// Called once when the child exits, with its status.
    var onExit: ((Int32) -> Void)? { get set }
    func start() throws
    /// Send text to the child's stdin. The caller includes any newline.
    func write(_ text: String)
    /// Ask the child to stop. Must be safe to call more than once, and after
    /// the child has already exited.
    func terminate()
}

/// Where the guided setup currently is. One enum for the whole flow — install
/// and login — because that is what the Settings row renders, and splitting it
/// would just mean reassembling it there.
enum ClaudeSetupState: Equatable {
    case idle
    /// Downloading the binary. `progress` is 0…1, or negative while the total
    /// size is unknown.
    case installing(progress: Double)
    /// `setup-token` is running; the authorization URL hasn't appeared yet.
    case signingIn
    /// The browser step. The URL is carried so the sheet can offer "open it
    /// again" without re-reading the transcript.
    case awaitingCode(URL)
    /// A code was submitted and the CLI is checking it.
    case verifying
    case ready
    case failed(String)

    /// Whether the flow is doing something the user should wait for. Drives the
    /// spinner and the disabled state of the setup button.
    var isBusy: Bool {
        switch self {
        case .installing, .signingIn, .verifying: return true
        case .idle, .awaitingCode, .ready, .failed: return false
        }
    }

    /// Log token. States that carry a payload deliberately drop it: the URL has
    /// a `state` parameter tied to a live OAuth exchange, and the failure
    /// reason can quote the CLI. Neither belongs in a world-readable log.
    var logToken: String {
        switch self {
        case .idle:         return "idle"
        case .installing:   return "installing"
        case .signingIn:    return "signing-in"
        case .awaitingCode: return "awaiting-code"
        case .verifying:    return "verifying"
        case .ready:        return "ready"
        case .failed:       return "failed"
        }
    }
}

/// Drives `claude setup-token` from launch to captured token.
///
/// ## The flow, and why each part is where it is
///
/// `setup-token` prints an authorization URL, waits for the user to authorize
/// in a browser, takes the resulting code on stdin, and prints a long-lived
/// token. Mila's job is to notice each of those moments and put a UI in front
/// of them. What makes that awkward is that the CLI is a TUI which produces
/// **no output at all** unless stdin is a terminal — verified: run with stdin
/// on a pipe it sits silently forever — so the transport has to be a pty.
///
/// The parsing lives in `ClaudeSetupTokenParser` (pure), the pty lives in
/// `PTYProcess` (untestable by nature), and this type is the state machine
/// between them — which is the part with the interesting bugs, and the part
/// the tests drive over recorded transcripts.
///
/// ## The token never reaches a log
///
/// The child's output *is* where the credential appears. So no code path here
/// logs output, and the only transcript that leaves this object goes through
/// `ClaudeSetupTokenParser.redact`. Failure messages built from CLI text are
/// redacted the same way before they are put into `.failed`, because a failure
/// message is rendered in the UI and could otherwise carry a token from a
/// partially-successful run.
@MainActor
final class ClaudeSetupTokenSession {

    /// How long to wait for the authorization URL after launching. The CLI
    /// prints it within a second in practice; this bound exists so a binary
    /// that hangs at startup fails visibly instead of leaving a spinner up.
    static let urlTimeout: TimeInterval = 90

    /// How long the user has to complete the browser half. Deliberately long —
    /// this includes a corporate SSO round trip, possibly a password manager
    /// and an MFA prompt — but not unbounded, so an abandoned sheet eventually
    /// releases the child process.
    static let authorizationTimeout: TimeInterval = 15 * 60

    /// How long to wait for a token after a code is submitted.
    static let verifyTimeout: TimeInterval = 120

    /// The three bounds above, in an injectable bundle.
    ///
    /// Injectable because a bound nobody has watched fire is a bound nobody
    /// knows works. The production values are minutes long by necessity — a
    /// real sign-in includes a human reading a browser page — so a test that
    /// used them would either take 90 seconds or, far more likely, not exist.
    /// With this seam the timeout path is driven in milliseconds.
    struct Timeouts {
        var url: TimeInterval = ClaudeSetupTokenSession.urlTimeout
        var authorization: TimeInterval = ClaudeSetupTokenSession.authorizationTimeout
        var verify: TimeInterval = ClaudeSetupTokenSession.verifyTimeout

        static let production = Timeouts()
    }

    private(set) var state: ClaudeSetupState = .idle {
        didSet {
            guard state != oldValue else { return }
            setupLog.notice("claude setup state=\(self.state.logToken, privacy: .public)")
            onStateChange?(state)
        }
    }

    /// Published upward. The settings object republishes it for SwiftUI; the
    /// tests read it directly.
    var onStateChange: ((ClaudeSetupState) -> Void)?

    /// Called with the authorization URL when Mila should open a browser
    /// itself. **Not** called when the CLI reported opening one — see
    /// `handle(_:)`. AppKit stays out of this file so the flow is testable.
    var onOpenURL: ((URL) -> Void)?

    /// Called exactly once with a captured token. The session does not store
    /// it: persistence is the settings object's job, and keeping the credential
    /// out of this object's fields keeps it out of anything that inspects them.
    var onToken: ((String) -> Void)?

    /// The transcript, with anything token-shaped replaced. Safe to show in a
    /// UI or attach to a diagnostic; deliberately the only accessor.
    var redactedTranscript: String { parser.redactedTranscript }

    /// Why the last submitted code was refused, if it was. Read by the sheet,
    /// cleared when the next code is submitted.
    private(set) var lastRejection: String?

    private let timeouts: Timeouts
    private let makeProcess: () -> ClaudeInteractiveProcess
    private var process: ClaudeInteractiveProcess?
    private var parser = ClaudeSetupTokenParser()
    private var deadline: Task<Void, Never>?
    private var finished = false
    private var authorizationURL: URL?
    private var cliOpenedBrowser = false

    init(timeouts: Timeouts = .production,
         makeProcess: @escaping () -> ClaudeInteractiveProcess) {
        self.timeouts = timeouts
        self.makeProcess = makeProcess
    }

    /// Convenience for production: run the managed binary's `setup-token`.
    static func managed(binary: URL) -> ClaudeSetupTokenSession {
        let environment = loginEnvironment(binary: binary)
        return ClaudeSetupTokenSession {
            PTYProcess(executable: binary,
                       arguments: ["setup-token"],
                       environment: environment)
        }
    }

    /// The environment the login child runs in: everything `LLMRunner` would
    /// normally give the managed binary, **minus any OAuth token**.
    ///
    /// This is the one child that must not inherit the credential. Every other
    /// invocation of the managed binary wants it (that is the whole point of
    /// `ClaudeManagedInstall.environmentAdditions`), but `setup-token` exists
    /// to *mint* a credential — handing it the one it is about to replace
    /// invites the CLI to treat the session as already authenticated, and a
    /// "sign in again" that silently hands back the OLD token is the failure
    /// mode hardest to notice: the UI would say Signed in, the Test would pass,
    /// and the credential the user was trying to replace would still be the
    /// live one. An inherited value the user set themselves is dropped for the
    /// same reason — for the duration of this one child only.
    static func loginEnvironment(
        binary: URL,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = LLMRunner.childEnvironment(for: binary,
                                                     base: base,
                                                     managedToken: { nil })
        environment.removeValue(forKey: ClaudeManagedInstall.oauthTokenEnvironmentKey)
        return environment
    }

    // MARK: - Driving

    func start() {
        guard case .idle = state else { return }
        finished = false
        parser = ClaudeSetupTokenParser()
        lastRejection = nil
        authorizationURL = nil
        cliOpenedBrowser = false
        state = .signingIn

        let child = makeProcess()
        child.onOutput = { [weak self] chunk in
            Task { @MainActor in self?.ingest(chunk) }
        }
        child.onExit = { [weak self] status in
            Task { @MainActor in self?.childExited(status: status) }
        }
        process = child
        do {
            try child.start()
        } catch {
            fail("Couldn't start the Claude CLI: \(error.localizedDescription)")
            return
        }
        arm(timeouts.url,
            reason: "Claude didn't produce a sign-in link. Try Reinstall, or set the CLI up in a terminal.")
    }

    /// Send the code the user pasted.
    ///
    /// Trimmed because a code copied out of a browser routinely brings a
    /// trailing newline or a stray space with it, and the CLI compares the
    /// whole line. The newline is ours to add: this is a pty, so the child's
    /// line discipline is what turns the write into a submitted line.
    func submit(code: String) {
        guard case .awaitingCode = state else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastRejection = nil
        state = .verifying
        process?.write(trimmed + "\n")
        arm(timeouts.verify,
            reason: "Claude didn't respond after the code was submitted.")
    }

    /// User closed the sheet or pressed Cancel.
    func cancel() {
        guard !finished else { return }
        finish()
        state = .idle
    }

    // MARK: - Reacting

    private func ingest(_ chunk: String) {
        guard !finished else { return }
        for event in parser.consume(chunk) {
            // Re-checked per event, not just once before the loop. One chunk
            // can complete several events, and any of them can be terminal —
            // a rejection with no authorization URL fails the flow, and the
            // same chunk can also carry something token-shaped. Checking only
            // on entry let the later event run against an already-finished
            // session, which turned a `.failed` into `.ready` and handed the
            // caller a token from a run that had just been reported as broken.
            guard !finished else { return }
            handle(event)
        }
    }

    private func handle(_ event: ClaudeSetupTokenParser.Event) {
        switch event {
        case .browserOpenedByCLI:
            // The CLI opens the browser itself ("· Opening browser to sign
            // in…"). Mila opening the same URL again would give the user two
            // tabs of the same OAuth request, so the sheet's "Open in browser"
            // button becomes the manual fallback instead of an automatic
            // second attempt.
            cliOpenedBrowser = true

        case .authorizationURL(let url):
            authorizationURL = url
            if case .signingIn = state { state = .awaitingCode(url) }
            if !cliOpenedBrowser { onOpenURL?(url) }
            arm(timeouts.authorization,
                reason: "Sign-in timed out. Start setup again when you're ready.")

        case .awaitingCode:
            if let authorizationURL, case .signingIn = state {
                state = .awaitingCode(authorizationURL)
            }

        case .codeRejected(let message):
            // Recoverable: the CLI re-prompts rather than exiting, so go back
            // to awaiting a code with the CLI's own explanation attached.
            guard let authorizationURL else {
                fail(ClaudeSetupTokenParser.redact(message))
                return
            }
            lastRejection = ClaudeSetupTokenParser.redact(message)
            state = .awaitingCode(authorizationURL)
            arm(timeouts.authorization,
                reason: "Sign-in timed out. Start setup again when you're ready.")

        case .token(let token):
            onToken?(token)
            finish()
            state = .ready
        }
    }

    private func childExited(status: Int32) {
        guard !finished else { return }
        // Last chance before this counts as a failure. While output was
        // streaming, the parser refused any token sitting at the very end of
        // the buffer, because a chunk boundary there could mean half a
        // credential. The stream is over now, so that ambiguity is gone and a
        // trailing token is safe to take.
        if let token = parser.finalToken() {
            onToken?(token)
            finish()
            state = .ready
            return
        }
        // Reaching here means the CLI ended without a token. Exit 0 is the
        // interesting case: it says the CLI thinks it succeeded while Mila
        // found nothing token-shaped in what it printed — the one scenario the
        // parser's doc comment warns about. Claiming success there would leave
        // a user "signed in" with no credential, so it is a failure with a
        // message that says what actually happened.
        if status == 0 {
            fail("Claude finished sign-in but didn't print a token Mila could read. Your CLI version may differ; you can still run `claude setup-token` in a terminal.")
        } else {
            fail("Claude's sign-in exited with status \(status).")
        }
    }

    private func fail(_ reason: String) {
        finish()
        state = .failed(reason)
    }

    /// Stop the child and the deadline. Idempotent — every terminal path calls
    /// it, including ones that race the child's own exit.
    private func finish() {
        finished = true
        deadline?.cancel()
        deadline = nil
        process?.terminate()
        process = nil
    }

    /// Replace the phase deadline. Cancelling the previous one is what makes
    /// these bounds *per phase* rather than cumulative: arriving at the next
    /// step is what buys more time.
    private func arm(_ seconds: TimeInterval, reason: String) {
        deadline?.cancel()
        deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.finished else { return }
            self.fail(reason)
        }
    }
}

// MARK: - Pseudo-terminal transport

/// Runs a child process with a pseudo-terminal on all three standard streams.
///
/// ## Why a pty and not a pipe
///
/// `claude setup-token` produces **nothing** on a pipe. Not an error, not a
/// prompt — it waits, silently, forever. (Verified against v2.1.260: 25s with
/// stdin on `/dev/null` produced zero bytes; the same command on a pty printed
/// its full UI immediately.) It is an Ink TUI and gates its entire render on
/// stdin being a terminal, so there is no non-interactive mode to fall back to.
///
/// macOS has no pty helper in Foundation, so this is the SUS/POSIX dance:
/// `posix_openpt` → `grantpt` → `unlockpt` → `ptsname` → `open`. `Process`
/// then gets the slave side on stdin/stdout/stderr, which is enough for
/// `isatty(0)` — the thing the TUI actually checks.
///
/// ## Subprocess rules
///
/// Follows `.claude/rules/python-subprocess.md` and `BlockingWork` (#251):
///
///  * `terminationHandler` is installed **before** `run()`, so the exit is
///    observed without a thread of ours blocked on it.
///  * The master-fd reader blocks until EOF, so it gets a **dedicated thread**
///    rather than a slot in the shared pool.
///  * The only wait is the SIGKILL escalation, and it is **bounded**.
///  * Writes go to a dedicated thread too: a pty master write can block when
///    the child isn't draining, and this is called from the main actor.
final class PTYProcess: ClaudeInteractiveProcess {

    var onOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    private let executable: URL
    private let arguments: [String]
    private let columns: Int
    private let workingDirectory: URL?
    private let environment: [String: String]

    private var process: Process?
    private var masterFD: Int32 = -1
    private let exited = DispatchSemaphore(value: 0)
    private let lock = NSLock()

    init(executable: URL,
         arguments: [String],
         columns: Int = ClaudeSetupTokenParser.terminalWidth,
         workingDirectory: URL? = nil,
         environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.columns = columns
        self.workingDirectory = workingDirectory
        self.environment = environment ?? LLMRunner.childEnvironment(for: executable)
    }

    /// `TIOCSWINSZ`, i.e. `_IOW('t', 103, struct winsize)` from
    /// `<sys/ttycom.h>`, computed rather than imported: Swift's C importer does
    /// not surface the `_IOW` macro, so the constant has to be assembled from
    /// the same pieces the macro uses — the "argument travels into the kernel"
    /// flag, the encoded argument size, the group character, and the number.
    private static var setWindowSizeRequest: UInt {
        let intoKernel: UInt = 0x8000_0000
        let encodedSize = UInt(MemoryLayout<winsize>.size & 0x1fff) << 16
        return intoKernel | encodedSize | (UInt(UInt8(ascii: "t")) << 8) | 103
    }

    enum PTYError: LocalizedError {
        case openFailed(String)
        var errorDescription: String? {
            switch self {
            case .openFailed(let detail): return "Couldn't open a terminal for the CLI (\(detail))."
            }
        }
    }

    func start() throws {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else { throw PTYError.openFailed("posix_openpt") }
        guard grantpt(master) == 0, unlockpt(master) == 0 else {
            close(master)
            throw PTYError.openFailed("grantpt/unlockpt")
        }
        guard let name = ptsname(master) else {
            close(master)
            throw PTYError.openFailed("ptsname")
        }
        let slave = open(name, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            close(master)
            throw PTYError.openFailed("open(slave)")
        }

        // A wide window so the TUI doesn't hard-wrap the authorization URL.
        // The parser can rejoin wrapped lines, but not wrapping in the first
        // place is the cheaper correctness. See `ClaudeSetupTokenParser`.
        var size = winsize(ws_row: 50, ws_col: UInt16(clamping: columns),
                           ws_xpixel: 0, ws_ypixel: 0)
        _ = withUnsafeMutablePointer(to: &size) {
            ioctl(master, Self.setWindowSizeRequest, UnsafeMutableRawPointer($0))
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        // Same reasoning as `LLMRunner.executeProcess`: a child that scans its
        // working directory makes macOS attribute the access to Mila's bundle
        // ID and prompts the user about folders Mila never asked for. The LLM
        // sandbox is a directory Mila owns that holds nothing.
        process.currentDirectoryURL = workingDirectory ?? LLMRunner.sandboxDirectory()

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        // Before `run()`, per the subprocess rules: the exit is observed by
        // Foundation's own reaping source, costing us no blocked thread.
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.exited.signal()
            self.onExit?(finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            close(slave)
            close(master)
            throw error
        }

        // Close OUR copy of the slave. The child holds its own; keeping this
        // one open would mean the master never sees EOF when the child exits,
        // and the reader thread below would block forever.
        close(slave)

        lock.withLock {
            self.process = process
            self.masterFD = master
        }
        startReader(master)
    }

    /// Drain the pty master until EOF, on a thread of its own.
    ///
    /// `read` blocks, so this must not be a pooled thread (#246). Decoding is
    /// per-chunk and lossy-tolerant: a chunk can split a multi-byte character,
    /// and dropping the odd replacement character costs nothing here — every
    /// marker this feeds is ASCII.
    private func startReader(_ fd: Int32) {
        BlockingWork.onDedicatedThread(named: "io.island.mila.claude-setup.pty") { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }   // EOF, or the master was closed
                let data = Data(buffer[0..<count])
                let text = String(decoding: data, as: UTF8.self)
                self?.onOutput?(text)
            }
        }
    }

    func write(_ text: String) {
        let fd = lock.withLock { masterFD }
        guard fd >= 0 else { return }
        let bytes = Array(text.utf8)
        BlockingWork.onDedicatedThread(named: "io.island.mila.claude-setup.write") {
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBufferPointer { pointer in
                    Darwin.write(fd, pointer.baseAddress, pointer.count)
                }
                if written <= 0 { break }
                offset += written
            }
        }
    }

    func terminate() {
        let (process, fd) = lock.withLock { (self.process, self.masterFD) }
        guard let process else {
            if fd >= 0 { closeMaster() }
            return
        }
        guard process.isRunning else {
            closeMaster()
            return
        }
        process.terminate()
        // Bounded escalation on a thread of its own — never an unbounded wait,
        // and never on the shared pool. If the CLI ignores SIGTERM (a TUI
        // restoring the terminal can take a moment) it gets killed.
        BlockingWork.onDedicatedThread(named: "io.island.mila.claude-setup.reap") { [weak self] in
            if self?.exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = self?.exited.wait(timeout: .now() + 3)
            }
            // Closing the master unblocks the reader thread's `read` even if a
            // grandchild inherited the slave and is holding it open.
            self?.closeMaster()
        }
    }

    private func closeMaster() {
        let fd = lock.withLock { () -> Int32 in
            let current = masterFD
            masterFD = -1
            return current
        }
        if fd >= 0 { close(fd) }
    }
}
