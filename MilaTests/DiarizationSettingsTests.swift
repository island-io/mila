import XCTest
@testable import Mila

@MainActor
final class DiarizationSettingsTests: XCTestCase {

    private var tempRoot: URL!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "DiarizationSettingsTests")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defaultsSuiteName = "DiarizationSettingsTests.\(UUID())"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let defaultsSuiteName { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        try await super.tearDown()
    }

    // MARK: - Regression test for the launch-time gate bug

    /// Regression: if the user previously enabled diarization AND torch was
    /// already installed in the user-writable site-packages, the first
    /// transcription after each app launch silently skipped diarization.
    ///
    /// Cause: `bootstrap.isReady` defaults to `false`, and the `didSet` on
    /// `isEnabled` that would have called `bootstrap.bootstrapIfNeeded()`
    /// (which calls `refreshReadyState()`) does NOT fire when the value is
    /// assigned in `init`. So the file-existence check that flips
    /// `isReady` to `true` never ran, and `isConfigured` returned `false`.
    ///
    /// Fix: `DiarizationSettings.init` now calls `bootstrap.refreshReadyState()`
    /// explicitly. This test stages a fake bundled-python + installed-torch
    /// layout, restores `isEnabled = true` from UserDefaults, and asserts
    /// the gate now reports configured at construction time.
    func test_init_refreshes_bootstrap_ready_state_so_isConfigured_is_true_at_launch() throws {
        let bundledPython = try makeFakeBundledPython()
        let sitePackages = try makeFakeTorchSitePackages()

        defaults.set(true, forKey: "diarization.enabled")

        let bootstrap = DiarizationBootstrap(bundledPython: bundledPython.path,
                                             sitePackages: sitePackages)
        XCTAssertFalse(bootstrap.isReady,
                       "Sanity: bootstrap.isReady must default to false; the fix is that init flips it.")

        let settings = DiarizationSettings(defaults: defaults, bootstrap: bootstrap)

        XCTAssertTrue(bootstrap.isReady,
                      "init must refresh bootstrap.isReady from disk; otherwise the gate locks closed even when torch is installed.")
        XCTAssertTrue(settings.hasBundledRuntime,
                      "hasBundledRuntime must reflect the injected bootstrap.")
        XCTAssertTrue(settings.isConfigured,
                      "isConfigured must be true when isEnabled persists + bootstrap files exist on disk.")
    }

    /// The opposite case: when torch is NOT yet installed (only bundled
    /// python exists), `isConfigured` must stay false so transcription
    /// proceeds without speaker labels rather than launching a subprocess
    /// that's doomed to fail.
    func test_init_leaves_isConfigured_false_when_torch_missing() throws {
        let bundledPython = try makeFakeBundledPython()
        let emptySitePackages = tempRoot.appendingPathComponent("empty-site")
        try FileManager.default.createDirectory(at: emptySitePackages, withIntermediateDirectories: true)

        defaults.set(true, forKey: "diarization.enabled")

        let bootstrap = DiarizationBootstrap(bundledPython: bundledPython.path,
                                             sitePackages: emptySitePackages)
        let settings = DiarizationSettings(defaults: defaults, bootstrap: bootstrap)

        XCTAssertFalse(bootstrap.isReady)
        XCTAssertTrue(settings.hasBundledRuntime)
        XCTAssertFalse(settings.isConfigured,
                       "isConfigured must remain false until torch is installed, even after the init refresh.")
    }

    // MARK: - Regression: enabling mid-session restores persisted verification

    /// Regression: launching with diarization OFF but a persisted verified
    /// setup, then flipping the toggle ON, showed "Setup needed" for a fully
    /// verified setup. The `isEnabled` didSet deliberately skips `checkDeps()`
    /// when `diarization.verified` is persisted — but nothing restored
    /// `verificationStatus` either (`restoreVerifiedState()` only ran in
    /// init, and only when the app launched already-enabled). `status` stayed
    /// at "Setup needed" (and on the legacy no-bundled-runtime flow, where
    /// `isConfigured` returns `status.isGood`, the whole feature stayed
    /// gated) until the user manually re-verified.
    func test_enabling_mid_session_restores_persisted_verified_state() throws {
        // A real file on disk so `pythonFound` is deterministic.
        let pythonStub = tempRoot.appendingPathComponent("python3")
        try Data().write(to: pythonStub)

        defaults.set(false, forKey: "diarization.enabled")
        defaults.set(true, forKey: "diarization.verified")
        defaults.set(pythonStub.path, forKey: "diarization.pythonPath")
        defaults.set(pythonStub.path, forKey: "diarization.verifiedPythonPath")

        // Inject a bootstrap that's already "ready" (fake bundled python +
        // installed torch) so the didSet's fire-and-forget
        // `bootstrapIfNeeded()` early-returns instead of downloading wheels
        // from the network inside a unit test.
        let bootstrap = DiarizationBootstrap(bundledPython: try makeFakeBundledPython().path,
                                             sitePackages: try makeFakeTorchSitePackages())
        let settings = DiarizationSettings(defaults: defaults, bootstrap: bootstrap)
        XCTAssertEqual(settings.status, .disabled, "Sanity: launched disabled")

        settings.isEnabled = true

        XCTAssertEqual(settings.status, .verified,
                       "Persisted verification must be restored when the user re-enables mid-session — not report 'Setup needed'")
        XCTAssertTrue(settings.status.isGood,
                      "status.isGood is what isConfigured returns on the legacy (no-bundled-runtime) flow — the restored verification must open that gate")
    }

    // MARK: - Regression: codesign_blocked must not trigger nuclear repair

    /// Regression: when macOS library validation refuses to dlopen torch's
    /// dylibs ("different Team IDs" — the interpreter is missing its
    /// disable-library-validation entitlement), the health check reported
    /// code "unknown" and took the nuclearRepair path: wipe the
    /// site-packages, re-download the ~62 MB wheels, ad-hoc re-sign — and
    /// fail with the exact same dlopen refusal. Net effect on an affected
    /// machine: a destructive multi-minute re-download on every launch with
    /// diarization permanently dead. Observed live in a user diagnostic
    /// (bootstrap pinned at `downloadingTorch(0.5)` while the health check
    /// kept surfacing the dlopen OSError).
    ///
    /// The health-check script now classifies that failure as a stable
    /// `codesign_blocked` code, and the self-heal loop must surface it
    /// WITHOUT wiping or re-bootstrapping anything.
    func test_health_check_codesign_blocked_surfaces_without_nuclear_repair() async throws {
        defaults.set(true, forKey: "diarization.enabled")

        let sitePackages = try makeFakeTorchSitePackages()
        let torchInit = sitePackages
            .appendingPathComponent("torch")
            .appendingPathComponent("__init__.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: torchInit.path), "Sanity: fixture staged")

        let bootstrap = DiarizationBootstrap(bundledPython: try makeFakeBundledPython().path,
                                             sitePackages: sitePackages)
        let settings = DiarizationSettings(defaults: defaults, bootstrap: bootstrap)
        let stageBefore = bootstrap.stage

        var runnerCalls = 0
        settings.healthCheckRunner = { _ in
            runnerCalls += 1
            return SpeakerDiarizer.HealthCheckResult(
                ok: false,
                error: "OSError: dlopen(.../libtorch_global_deps.dylib, 0x000A): ... different Team IDs",
                code: "codesign_blocked"
            )
        }

        await settings.runHealthCheck()

        XCTAssertEqual(runnerCalls, 1,
                       "codesign_blocked is not recoverable by reinstalling — the loop must stop after the first check, not retry")
        XCTAssertEqual(settings.healthCheckResult?.code, "codesign_blocked",
                       "The structured code must surface so Settings can show an actionable message")
        XCTAssertTrue(FileManager.default.fileExists(atPath: torchInit.path),
                      "nuclearRepair must NOT run: the installed site-packages must survive the health check untouched")
        XCTAssertEqual(bootstrap.stage, stageBefore,
                       "No re-bootstrap: the stage must not move (a repair would reset it and start downloading)")
        XCTAssertFalse(settings.isInstalling,
                       "No install may be left in flight")
    }

    // MARK: - Fixtures

    private func makeFakeBundledPython() throws -> URL {
        let url = tempRoot.appendingPathComponent("python3.11")
        try Data().write(to: url)
        return url
    }

    private func makeFakeTorchSitePackages() throws -> URL {
        let site = tempRoot.appendingPathComponent("torch-site")
        for pkg in ["torch", "torchaudio"] {
            let initFile = site.appendingPathComponent(pkg).appendingPathComponent("__init__.py")
            try FileManager.default.createDirectory(at: initFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: initFile)
        }
        return site
    }
}
