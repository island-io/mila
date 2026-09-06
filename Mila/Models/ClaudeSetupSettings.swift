import Foundation
import Combine
import os

private let setupSettingsLog = os.Logger(subsystem: "io.island.whisper.IslandWhisper",
                                         category: "ClaudeSetup")

/// What the Settings row says about the managed Claude install, at a glance.
///
/// Three resting states, matching the three things that can actually be true —
/// nothing installed, installed but no credential, both — plus the transient
/// and broken cases. Kept as one enum so the row cannot render a combination
/// that doesn't exist (a "Signed in" badge with no binary, say).
enum ClaudeSetupStatus: Equatable {
    case notSetUp
    case installedNotSignedIn
    /// `verified` is true only when a Test run has actually succeeded against
    /// this exact binary and credential — see `ClaudeSetupSettings.status` for
    /// why that is not the same as "we have a token".
    case signedIn(verified: Bool)
    /// The user already has their own `claude` (npm, the official installer,
    /// anything `LLMRunner`'s search finds) and no managed copy is installed.
    /// That setup is complete as far as Mila is concerned — it must not read
    /// as "Not set up" just because *this* button didn't produce it.
    case usingSystemCLI(verified: Bool)
    case working(String)
    case problem(String)

    var label: String {
        switch self {
        case .notSetUp:              return "Not set up"
        case .installedNotSignedIn:  return "Installed, not signed in"
        case .signedIn(let verified): return verified ? "Signed in and working" : "Signed in"
        case .usingSystemCLI(let verified):
            return verified ? "Using your Claude CLI — working" : "Using your Claude CLI"
        case .working(let what):     return what
        case .problem(let message):  return message
        }
    }

    var symbolName: String {
        switch self {
        case .notSetUp:             return "circle.dashed"
        case .installedNotSignedIn: return "person.crop.circle.badge.questionmark"
        case .signedIn(let verified): return verified ? "checkmark.circle.fill" : "checkmark.circle"
        case .usingSystemCLI(let verified): return verified ? "checkmark.circle.fill" : "checkmark.circle"
        case .working:              return "arrow.triangle.2.circlepath"
        case .problem:              return "exclamationmark.triangle.fill"
        }
    }

    /// True when Mila can run a Claude CLI right now (managed or the user's own).
    var isReady: Bool {
        switch self {
        case .signedIn, .usingSystemCLI: return true
        default: return false
        }
    }
}

/// App-wide state for the one-button Claude setup (issue #271).
///
/// Owns three things that have to agree with each other: whether a managed
/// binary is on disk, whether a token is in the Keychain, and whether the pair
/// has been proven to work. Everything else — the download, the pty login, the
/// keychain — happens behind the seams this object is constructed with, so a
/// test can drive the whole surface with no network, no subprocess and no
/// keychain.
///
/// Follows the conventions in `CLAUDE.md`: namespaced `claudeSetup.*` defaults
/// keys, a persisted `verified` flag restored only when the parameters it was
/// recorded against still match, and a computed `status` that consults the
/// persisted verification before any in-memory result.
@MainActor
final class ClaudeSetupSettings: ObservableObject {

    // MARK: - Published state

    @Published private(set) var state: ClaudeSetupState = .idle
    @Published private(set) var isInstalled: Bool = false
    @Published private(set) var installedVersion: String?
    @Published private(set) var hasToken: Bool = false

    /// Where a non-managed `claude` was found, if anywhere — the same search
    /// `LLMRunner` performs minus the managed copy. Drives `.usingSystemCLI`,
    /// and shown as the caption path so the user knows which binary Mila runs.
    @Published private(set) var systemCLIPath: String?

    /// Outcome of the most recent Test run, kept for the row's detail text.
    /// Not persisted — `verified` below is the durable half.
    @Published private(set) var lastTestResult: LLMTestResult?
    @Published private(set) var isTesting = false

    /// Set when a sign-out could not remove the credential. The UI must keep
    /// showing "signed in" in that case: an affordance that claims to have
    /// removed a credential it did not remove is the one state to never show.
    @Published private(set) var signOutFailed = false

    /// The live login flow, non-nil only while a sign-in is in progress.
    /// The sheet binds to this object; `session?.lastRejection` is what it
    /// renders under the code field.
    @Published private(set) var session: ClaudeSetupTokenSession?

    // MARK: - Verification (persisted)

    /// "A Test run succeeded, and nothing has changed since." Restored from
    /// defaults on launch, but only when the *parameters* it was recorded
    /// against still hold — see `restoreVerification`.
    @Published private(set) var verified = false

    // MARK: - Seams

    private let defaults: UserDefaults
    private let tokenStore: ClaudeTokenStoring
    private let installer: ClaudeBinaryInstaller
    private let appSupportRoot: URL
    private let fileManager: FileManager
    /// Injected so tests never open a browser, and so `NSWorkspace` (AppKit)
    /// stays out of the model layer.
    private let openURL: (URL) -> Void
    /// Injected so the Test button can be exercised without running a CLI.
    private let runTest: (URL, TimeInterval) async -> LLMTestResult
    /// Injected so tests control whether a "system" claude exists. The default
    /// is `LLMRunner`'s own search with the managed copy excluded, so this
    /// answers exactly one question: what would Mila run if we hadn't
    /// installed anything?
    private let systemCLILookup: () -> URL?

    private var installTask: Task<Void, Never>?
    /// Which install currently owns the published state. A cancelled install
    /// can outlive its cancellation (blocked in `installer.install` until the
    /// transfer notices), and its terminal writes must not level a replacement
    /// install the user started in the meantime. Bumped by every new install
    /// and by every cancel; a task whose generation is stale writes nothing.
    private var installGeneration = 0

    init(defaults: UserDefaults = .standard,
         tokenStore: ClaudeTokenStoring = KeychainClaudeTokenStore(),
         installer: ClaudeBinaryInstaller? = nil,
         appSupportRoot: URL = ClaudeManagedInstall.applicationSupportRoot(),
         fileManager: FileManager = .default,
         openURL: @escaping (URL) -> Void = { _ in },
         runTest: ((URL, TimeInterval) async -> LLMTestResult)? = nil,
         systemCLILookup: (() -> URL?)? = nil) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.appSupportRoot = appSupportRoot
        self.fileManager = fileManager
        self.installer = installer ?? ClaudeBinaryInstaller(appSupportRoot: appSupportRoot)
        self.openURL = openURL
        self.systemCLILookup = systemCLILookup ?? {
            try? LLMRunner.resolveExecutable(tool: .claude, override: nil, managedBinary: nil)
        }
        self.runTest = runTest ?? { binary, timeout in
            // The real probe: the smallest useful thing the CLI can do. It goes
            // through `LLMRunner`, so it exercises the same executable
            // resolution and the same environment — including the token
            // injection — that a real summary would.
            await LLMRunner.diagnose(tool: .claude,
                                     prompt: "Reply with the single word OK.",
                                     transcript: "",
                                     executablePathOverride: binary.path,
                                     timeout: timeout,
                                     feature: .settingsTest)
        }
        refreshInstalledState()
        restoreVerification()
    }

    // MARK: - Status

    /// The single value the Settings row renders.
    ///
    /// Order matters, and it is the order `DiarizationSettings.status` uses:
    /// a transient state wins (the user is watching something happen), then the
    /// persisted verification, then the plain facts on disk. Consulting
    /// `lastTestResult` before `verified` would mean a launch with no in-memory
    /// result showed "Signed in" for a setup that was proven working yesterday
    /// — the persisted answer is the better one, and it is the one that
    /// survives a relaunch.
    var status: ClaudeSetupStatus {
        switch state {
        case .installing(let progress):
            let percent = progress >= 0 ? " \(Int(progress * 100))%" : ""
            return .working("Downloading Claude\(percent)")
        case .signingIn:     return .working("Opening sign-in…")
        case .awaitingCode:  return .working("Waiting for the code from your browser")
        case .verifying:     return .working("Checking the code…")
        case .failed(let reason): return .problem(reason)
        case .idle, .ready:  break
        }
        if isTesting { return .working("Testing…") }
        guard isInstalled else {
            // No managed copy — but a claude the user installed themselves is
            // a complete setup, not an absent one. The managed flow stays
            // available as an optional extra in that state.
            if systemCLIPath != nil { return .usingSystemCLI(verified: verified) }
            return .notSetUp
        }
        guard hasToken else { return .installedNotSignedIn }
        if verified { return .signedIn(verified: true) }
        if let result = lastTestResult, result.succeeded { return .signedIn(verified: true) }
        return .signedIn(verified: false)
    }

    /// Whether the managed binary is what `LLMRunner` will pick. Shown as a
    /// caption so a user with their own `claude` on `PATH` understands which
    /// one Mila is actually running.
    var managedBinaryPath: String {
        ClaudeManagedInstall.binaryURL(appSupportRoot: appSupportRoot).path
    }

    // MARK: - Install

    /// The one button. Installs if needed, then starts the guided login.
    func setUp() {
        guard !state.isBusy else { return }
        installTask?.cancel()
        installGeneration += 1
        let generation = installGeneration
        installTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.isInstalled {
                guard await self.performInstall(generation: generation) else { return }
            }
            guard generation == self.installGeneration else { return }
            self.startSignIn()
        }
    }

    /// Re-download the binary, keeping any existing credential.
    ///
    /// The v1 update story: there is no background updater and no version
    /// check against the release feed, because the failure this has to cover is
    /// "my CLI stopped working", not "my CLI is 3 days old". A user who sees a
    /// failure presses this and gets the current release.
    func reinstall() {
        guard !state.isBusy else { return }
        installTask?.cancel()
        installGeneration += 1
        let generation = installGeneration
        installTask = Task { @MainActor [weak self] in
            _ = await self?.performInstall(generation: generation)
        }
    }

    private func performInstall(generation: Int) async -> Bool {
        guard generation == installGeneration else { return false }
        state = .installing(progress: -1)
        do {
            let result = try await installer.install { progress in
                Task { @MainActor [weak self] in
                    guard let self, generation == self.installGeneration,
                          case .installing = self.state else { return }
                    self.state = .installing(progress: progress)
                }
            }
            // The disk has changed no matter who owns the flow now: a cancel
            // that raced the last stretch of the install cannot un-write
            // `moveIntoPlace`. Everything that MIRRORS disk — the version
            // default, the installed flags, the now-invalid verification —
            // must therefore be recorded even for a superseded generation, or
            // Settings describes a machine that no longer exists (and keeps a
            // "verified" claim about bytes that were just replaced).
            installedVersion = result.version
            defaults.set(result.version, forKey: Keys.installedVersion)
            refreshInstalledState()
            // A new binary invalidates the proof: the Test that passed was
            // against the *previous* one. `restoreVerification`'s parameter
            // check would catch this on the next launch anyway; clearing it now
            // means the UI doesn't claim a verification it no longer has.
            clearVerification()
            // Only the flow-owned writes stay generation-guarded: the spinner
            // state and the chained sign-in belong to whoever runs NOW.
            guard generation == installGeneration else { return false }
            state = .idle
            return true
        } catch is CancellationError {
            if generation == installGeneration { state = .idle }
            return false
        } catch {
            guard generation == installGeneration else { return false }
            // A cancelled URLSession task surfaces as `URLError.cancelled`,
            // not `CancellationError` — either way the user asked for it, so
            // it must not render as a failure.
            if Task.isCancelled {
                state = .idle
                return false
            }
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            state = .failed(message)
            return false
        }
    }

    // MARK: - Sign in

    /// Start (or restart) the guided login against the installed binary.
    func startSignIn() {
        guard isInstalled else {
            state = .failed("Claude isn't installed yet.")
            return
        }
        guard !state.isBusy else { return }
        let binary = ClaudeManagedInstall.binaryURL(appSupportRoot: appSupportRoot)
        let session = ClaudeSetupTokenSession.managed(binary: binary)
        session.onStateChange = { [weak self] newState in
            guard let self else { return }
            // The session reports `.ready` right after delivering the token —
            // but `onToken` runs first, and `store(_:)` may have just recorded
            // a Keychain failure there. That failure is the truer state: the
            // session only knows the CLI handed a token over, not whether it
            // could be kept. Copying `.ready` over it would silently bury the
            // one error the user has to act on.
            if case .ready = newState, case .failed = self.state {
                // keep the failure; fall through so the session is still released
            } else {
                self.state = newState
            }
            switch newState {
            case .ready, .failed, .idle:
                // Released on the NEXT main-actor turn, not here. This property
                // holds the only strong reference to the session, and this
                // closure is called from inside the session's own `state`
                // `didSet` — so clearing it inline drops the last reference to
                // an object with a method still on the stack. It survives today
                // only because every caller reaches the session through
                // optional chaining on a weak `self`, which happens to hold a
                // temporary strong reference for the duration. That is a
                // property of the call sites, not of this code, and a refactor
                // there would turn this into a use-after-free with no local
                // evidence of why.
                //
                // The identity guard matters as much as the deferral: a user
                // who presses "Try again" on a failure starts a NEW session
                // before this task runs, and an unguarded `session = nil` would
                // tear down the sign-in they just started.
                Task { @MainActor [weak self, weak session] in
                    guard let self, self.session === session else { return }
                    self.session = nil
                }
            case .installing, .signingIn, .awaitingCode, .verifying:
                break
            }
        }
        session.onOpenURL = { [weak self] url in self?.openURL(url) }
        session.onToken = { [weak self] token in self?.store(token) }
        self.session = session
        session.start()
    }

    /// Send the code the user pasted out of their browser.
    func submit(code: String) {
        session?.submit(code: code)
    }

    /// Abandon whatever the Cancel button is looking at: an in-progress
    /// download, a sign-in, or an install that would chain into one.
    ///
    /// Cancelling `installTask` matters even mid-download: without it the
    /// transfer keeps running, and `setUp()`'s task would then proceed to
    /// `startSignIn()` and open a browser the user has already walked away
    /// from.
    func cancelSignIn() {
        installTask?.cancel()
        // Disown the cancelled task's future writes as well as cancelling it:
        // it may be parked inside `installer.install` past the cancel, and its
        // eventual terminal state belongs to nobody now.
        installGeneration += 1
        session?.cancel()
        session = nil
        switch state {
        case .signingIn, .awaitingCode, .verifying, .installing: state = .idle
        case .idle, .ready, .failed: break
        }
    }

    /// Persist a captured token.
    ///
    /// The token is never logged, never put in `UserDefaults`, and is not held
    /// as a property of this object: it goes straight to the store, and
    /// everything afterwards works off `hasToken`.
    private func store(_ token: String) {
        guard tokenStore.save(token) else {
            state = .failed("Mila couldn't save the Claude credential to your Keychain.")
            return
        }
        hasToken = true
        // A fresh credential has not been proven to work yet — the Test button
        // is what turns "Signed in" into "Signed in and working".
        clearVerification()
        setupSettingsLog.notice("claude setup token stored")
    }

    // MARK: - Sign out

    /// Remove the stored credential, and optionally the binary with it.
    ///
    /// The delete is verified before any UI state changes. `ClaudeTokenStoring`
    /// exists in that shape for this method: flipping to "signed out" over a
    /// credential still in the keychain would be a lie the user cannot see
    /// through.
    func signOut(removeBinary: Bool = false) {
        let removed = tokenStore.delete()
        guard removed else {
            signOutFailed = true
            hasToken = true
            setupSettingsLog.error("claude setup sign-out failed — credential still present")
            return
        }
        signOutFailed = false
        hasToken = false
        clearVerification()
        lastTestResult = nil
        if removeBinary {
            _ = installer.removeManagedBinary()
            defaults.removeObject(forKey: Keys.installedVersion)
            installedVersion = nil
        }
        refreshInstalledState()
        state = .idle
    }

    // MARK: - Test

    /// The binary a Test run (and `LLMRunner` itself) would use: the managed
    /// copy when installed, otherwise the user's own CLI if one was found.
    var effectiveBinaryPath: String? {
        if isInstalled { return managedBinaryPath }
        return systemCLIPath
    }

    /// Run one trivial prompt through the effective binary and record whether
    /// it worked. Bounded — a hung CLI must not leave the row spinning.
    func test() async {
        guard !isTesting, let binaryPath = effectiveBinaryPath else { return }
        isTesting = true
        lastTestResult = nil
        defer { isTesting = false }
        let binary = URL(fileURLWithPath: binaryPath)
        let result = await runTest(binary, Self.testTimeout)
        lastTestResult = result
        if result.succeeded {
            recordVerification()
        } else {
            clearVerification()
        }
    }

    /// Bound on the Test run. Short: this prompt asks for one word, so anything
    /// slower than this is a broken setup rather than a slow model.
    static let testTimeout: TimeInterval = 90

    // MARK: - Persistence

    private func refreshInstalledState() {
        isInstalled = ClaudeManagedInstall.isInstalled(fileManager: fileManager,
                                                       appSupportRoot: appSupportRoot)
        if installedVersion == nil {
            installedVersion = defaults.string(forKey: Keys.installedVersion)
        }
        hasToken = tokenStore.load() != nil
        systemCLIPath = systemCLILookup()?.path
    }

    /// Restore the persisted "this setup was proven to work" flag — but only if
    /// every parameter it was recorded against still matches.
    ///
    /// The parameters are the binary path, the installed version, and the
    /// continued presence of a credential. Any of them changing means the proof
    /// was about a different setup: a reinstall brings new bytes, and a
    /// sign-out removes the credential the test passed with. This mirrors
    /// `DiarizationSettings`, which restores its verified flag only when the
    /// persisted Python path still equals the configured one.
    private func restoreVerification() {
        guard defaults.bool(forKey: Keys.verified) else { return }
        let recordedPath = defaults.string(forKey: Keys.verifiedBinaryPath)
        if isInstalled {
            guard hasToken else { return }
            guard recordedPath == managedBinaryPath else { return }
            let recordedVersion = defaults.string(forKey: Keys.verifiedVersion)
            guard recordedVersion == installedVersion else { return }
            verified = true
        } else if let systemCLIPath {
            // The user's own CLI carries its own login (`~/.claude`), so there
            // is no token requirement here. The proof is only about identity:
            // the binary that passed the Test is still the one Mila would run.
            guard recordedPath == systemCLIPath else { return }
            verified = true
        }
    }

    private func recordVerification() {
        verified = true
        defaults.set(true, forKey: Keys.verified)
        defaults.set(effectiveBinaryPath, forKey: Keys.verifiedBinaryPath)
        if isInstalled {
            defaults.set(installedVersion, forKey: Keys.verifiedVersion)
        } else {
            // A system CLI has no managed version to pin the proof to; leaving
            // a stale managed version here would block the restore above.
            defaults.removeObject(forKey: Keys.verifiedVersion)
        }
    }

    private func clearVerification() {
        verified = false
        defaults.set(false, forKey: Keys.verified)
        defaults.removeObject(forKey: Keys.verifiedBinaryPath)
        defaults.removeObject(forKey: Keys.verifiedVersion)
    }

    enum Keys {
        static let installedVersion = "claudeSetup.installedVersion"
        static let verified = "claudeSetup.verified"
        static let verifiedBinaryPath = "claudeSetup.verifiedBinaryPath"
        static let verifiedVersion = "claudeSetup.verifiedVersion"
    }
}
