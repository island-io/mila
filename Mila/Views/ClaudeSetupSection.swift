import SwiftUI
import AppKit

/// Settings → AI Provider → "Set up Claude": the one-button managed install
/// (issue #271).
///
/// Lives in its own file rather than inside `SettingsView.swift` because the
/// section is a self-contained flow — install, guided login, test, sign out —
/// with its own sheet, and `SettingsView.swift` is already long. The cost is
/// that the private layout helpers there (`AICaption`, `aiLabelWidth`) are not
/// visible here, so the few bits of chrome this needs are restated below with
/// the same metrics.
///
/// ## Why this section exists at all
///
/// Everything it does was previously possible: install the CLI with a
/// `curl … | bash` line, run `claude setup-token` in a terminal, and let
/// `LLMRunner`'s `$PATH` search (#196) find the result. The section is here for
/// the users who will not do that — for whom "open Terminal" is where the
/// feature ends. So the design rule throughout is that no step asks the user to
/// leave Mila except the one that genuinely cannot happen anywhere else:
/// authorizing in their browser.
struct ClaudeSetupSection: View {

    @EnvironmentObject private var setup: ClaudeSetupSettings

    /// The pasted code. Held here rather than in the settings object because it
    /// is view state with a lifetime of exactly one sheet — and because a
    /// half-typed authorization code has no business being reachable from the
    /// app-wide model.
    @State private var code = ""
    @State private var showRemoveConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            statusRow
            if case .installing(let progress) = setup.state {
                installProgress(progress)
            }
            buttons
            caption
            if let result = setup.lastTestResult, !result.succeeded {
                testFailure(result)
            }
            if setup.signOutFailed {
                signOutWarning
            }
        }
        .sheet(isPresented: sheetPresented) { codeSheet }
        .confirmationDialog("Remove Claude from Mila?",
                            isPresented: $showRemoveConfirmation,
                            titleVisibility: .visible) {
            Button("Sign out only") { setup.signOut() }
            Button("Sign out and delete the binary", role: .destructive) {
                setup.signOut(removeBinary: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Signing out removes the Claude credential from your Keychain. Deleting the binary also removes Mila's copy of the Claude CLI — a `claude` you installed yourself is never touched.")
        }
    }

    // MARK: - Header and status

    private var header: some View {
        Text("Set up Claude")
            .font(.callout.weight(.semibold))
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: setup.status.symbolName)
                .foregroundStyle(statusColor)
                // A spinner would be more literal for `.working`, but the row
                // has to hold its height across every state or the buttons
                // below it jump on each transition.
                .symbolRenderingMode(.hierarchical)
            Text(setup.status.label)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("ai.provider.claudeSetup.status")
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch setup.status {
        case .signedIn(let verified): return verified ? .green : .secondary
        // Green even before a Test run: the user's own CLI being found IS the
        // good state — rendering it grey made a working setup read as a chore
        // still to do.
        case .usingSystemCLI:         return .green
        case .problem:                return .orange
        case .working:                return .secondary
        case .notSetUp,
             .installedNotSignedIn:   return .secondary
        }
    }

    private func installProgress(_ progress: Double) -> some View {
        Group {
            if progress >= 0 {
                ProgressView(value: progress)
            } else {
                // Negative means the server did not send a length. An
                // indeterminate bar is honest about that; a bar pinned at 0
                // reads as a stalled download.
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .frame(maxWidth: captionWidth)
    }

    // MARK: - Buttons

    /// One primary action whose label follows the state, plus the maintenance
    /// actions once there is something to maintain. Deliberately not five
    /// buttons at once: before setup there is exactly one thing to do.
    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            switch setup.status {
            case .notSetUp:
                Button("Set up Claude") { setup.setUp() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ai.provider.claudeSetup.setUp")

            case .installedNotSignedIn:
                Button("Sign in to Claude") { setup.startSignIn() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ai.provider.claudeSetup.signIn")
                reinstallButton

            case .signedIn:
                testButton
                reinstallButton
                Button("Sign out…") { showRemoveConfirmation = true }
                    .accessibilityIdentifier("ai.provider.claudeSetup.signOut")

            case .usingSystemCLI:
                // Nothing to fix here, so no prominent button: Test to prove
                // the login, and the managed install as an opt-in extra (it
                // takes precedence once installed).
                testButton
                Button("Install Mila's own copy…") { setup.setUp() }
                    .accessibilityIdentifier("ai.provider.claudeSetup.installManaged")

            case .working:
                if setup.isTesting {
                    // A Test run is bounded (90s) and has no cancel path, so
                    // showing a Cancel here would be a button that does
                    // nothing. The spinner-labelled test button is the honest
                    // rendering of this state.
                    testButton
                } else {
                    Button("Cancel") { setup.cancelSignIn() }
                        .accessibilityIdentifier("ai.provider.claudeSetup.cancel")
                }

            case .problem:
                // A failure is the one state where "try the whole thing again"
                // is the likeliest next action, so it gets the prominent slot
                // regardless of how far the previous attempt got.
                Button("Try again") { setup.setUp() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ai.provider.claudeSetup.retry")
                if setup.isInstalled { reinstallButton }
            }
            Spacer(minLength: 0)
        }
    }

    private var testButton: some View {
        Button {
            Task { await setup.test() }
        } label: {
            if setup.isTesting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Testing…")
                }
            } else {
                Text("Test")
            }
        }
        .disabled(setup.isTesting)
        .accessibilityIdentifier("ai.provider.claudeSetup.test")
    }

    private var reinstallButton: some View {
        Button("Reinstall") { setup.reinstall() }
            .disabled(setup.state.isBusy)
            .accessibilityIdentifier("ai.provider.claudeSetup.reinstall")
    }

    // MARK: - Captions

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            if case .usingSystemCLI = setup.status, let path = setup.systemCLIPath {
                Text("Mila found the Claude CLI you already installed and uses it as-is. Installing Mila's own copy is optional; it would take over from this one.")
                Text(verbatim: path)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            } else {
                Text("Mila downloads Anthropic's official Claude CLI, checks its Apple code signature before running it, and keeps it in its own folder. Your Claude subscription signs in through your browser.")
            }
            if setup.isInstalled {
                Text(verbatim: setup.managedBinaryPath)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                if let version = setup.installedVersion {
                    Text("Version \(version)")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: captionWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func testFailure(_ result: LLMTestResult) -> some View {
        // The Test button's own failure text. Kept to the setup error or the
        // tail of stderr: this row is a status line, not the AI Provider test
        // panel, which is where the full command and output already live.
        Text(result.setupError ?? shortFailure(result))
            .font(.caption)
            .foregroundStyle(.orange)
            .frame(maxWidth: captionWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func shortFailure(_ result: LLMTestResult) -> String {
        if result.timedOut { return "The test timed out." }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return String(stderr.suffix(300)) }
        return "The test exited with status \(result.exitCode.map(String.init) ?? "unknown")."
    }

    private var signOutWarning: some View {
        Label {
            Text("Mila could not remove the credential from your Keychain, so you are still signed in. Open Keychain Access and delete the \"\(KeychainClaudeTokenStore.defaultKey)\" item.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .frame(maxWidth: captionWidth, alignment: .leading)
    }

    // MARK: - Code sheet

    /// The sheet is driven by the flow's own state, not by whether a session
    /// object exists. The session is cleared on terminal states, and tying the
    /// sheet to its lifetime would make dismissal depend on deallocation order.
    private var sheetPresented: Binding<Bool> {
        Binding(
            get: {
                switch setup.state {
                case .awaitingCode, .verifying: return true
                default: return false
                }
            },
            set: { presented in
                // Dismissing the sheet abandons the login; the child process
                // has to go with it, or a pty sits waiting on a code nobody is
                // going to type.
                if !presented { setup.cancelSignIn() }
            }
        )
    }

    private var authorizationURL: URL? {
        if case .awaitingCode(let url) = setup.state { return url }
        return nil
    }

    private var isVerifying: Bool {
        if case .verifying = setup.state { return true }
        return false
    }

    private var codeSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Finish signing in to Claude")
                .font(.headline)

            Text("Your browser should have opened Anthropic's sign-in page. Approve the request there, then copy the code it gives you and paste it below.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let authorizationURL {
                Button("Open the sign-in page again") {
                    NSWorkspace.shared.open(authorizationURL)
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("ai.provider.claudeSetup.reopenURL")
            }

            TextField("Paste the code here", text: $code)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .disabled(isVerifying)
                .onSubmit(submit)
                .accessibilityIdentifier("ai.provider.claudeSetup.code")

            if let rejection = setup.session?.lastRejection {
                Label {
                    Text(rejection)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { setup.cancelSignIn() }
                Button {
                    submit()
                } label: {
                    if isVerifying {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Text("Continue")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isVerifying || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("ai.provider.claudeSetup.submitCode")
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func submit() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isVerifying else { return }
        setup.submit(code: trimmed)
        // Clear immediately: the code has been handed to the CLI, and leaving
        // it in a `@State` string keeps a one-time credential alive in the view
        // hierarchy for as long as Settings stays open.
        code = ""
    }

    /// Matches `aiCaptionWidth` in `SettingsView.swift`, which is private to
    /// that file.
    private let captionWidth: CGFloat = 520
}
