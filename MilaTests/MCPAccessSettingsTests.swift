import XCTest
import MilaKit
@testable import Mila

/// `MCPAccessSettings` mirrors the user's consent into `mcp-access.json`,
/// which is the only thing the out-of-process helper can read. Two invariants
/// matter more than the happy path:
///
///   * revoking must fail CLOSED (CodeRabbit on #183, CWE-359), and
///   * consent alone must not be enough — the store also has to be
///     discoverable, or the helper would answer from a stale one.
@MainActor
final class MCPAccessSettingsTests: XCTestCase {

    private var root: URL!
    private let suite = "MCPAccessSettingsTests.mcp"

    override func setUp() async throws {
        try await super.setUp()
        root = TestSupport.makeTempRoot(label: "MCPAccessSettingsTests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        UserDefaults().removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        setRootWritable(true)
        if let root { try? FileManager.default.removeItem(at: root) }
        UserDefaults().removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    private func setRootWritable(_ writable: Bool) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o500], ofItemAtPath: root.path)
    }

    private func settings(storeIsDiscoverable: @escaping () -> Bool = { true })
        -> MCPAccessSettings {
        MCPAccessSettings(defaults: UserDefaults(suiteName: suite)!,
                          root: root,
                          storeIsDiscoverable: storeIsDiscoverable)
    }

    // MARK: - The happy path still works

    func test_toggle_mirrors_consent_in_both_directions() {
        let s = settings()
        XCTAssertFalse(s.enabled, "off by default")
        XCTAssertFalse(MCPAccessGate.isEnabled(root: root))

        s.enabled = true
        XCTAssertTrue(MCPAccessGate.isEnabled(root: root))
        XCTAssertNil(s.mirrorError)
        XCTAssertFalse(s.revocationFailed)

        s.enabled = false
        XCTAssertFalse(MCPAccessGate.isEnabled(root: root))
        XCTAssertFalse(s.revocationFailed)
    }

    // MARK: - Revocation fails closed

    /// REGRESSION: when the atomic write failed while DISABLING, the existing
    /// `enabled: true` file survived — so the toggle read off in the UI while
    /// a configured MCP client kept reading transcripts. Revocation now
    /// escalates to deleting the file; when even that is impossible, the
    /// toggle is put back to ON, because that is the truth.
    func test_failed_revocation_keeps_the_toggle_honest() throws {
        let s = settings()
        s.enabled = true
        XCTAssertTrue(MCPAccessGate.isEnabled(root: root))

        // Defeats both the atomic write and the removal.
        setRootWritable(false)
        s.enabled = false

        XCTAssertTrue(MCPAccessGate.isEnabled(root: root),
                      "precondition: the gate really is still granting access")
        XCTAssertTrue(s.enabled,
                      "the toggle must not claim to be off while the helper still has access")
        XCTAssertTrue(s.revocationFailed, "and the UI needs to be able to say why")
        XCTAssertEqual(UserDefaults(suiteName: suite)?.bool(forKey: MCPAccessSettings.Keys.enabled),
                       true,
                       "the persisted preference must match the toggle, or a relaunch would "
                       + "silently re-open the gap")
    }

    /// Once the obstruction clears, turning it off works normally — the forced
    /// restore above is a reflection of reality, not a latch.
    func test_revocation_succeeds_once_the_obstruction_clears() throws {
        let s = settings()
        s.enabled = true
        setRootWritable(false)
        s.enabled = false
        XCTAssertTrue(s.enabled)

        setRootWritable(true)
        s.enabled = false

        XCTAssertFalse(s.enabled)
        XCTAssertFalse(s.revocationFailed)
        XCTAssertFalse(MCPAccessGate.isEnabled(root: root))
    }

    /// Failing to GRANT is the safe direction and must not be dressed up as a
    /// revocation problem: the gate keeps denying, which is what the user's
    /// unwritten preference would have asked for anyway.
    func test_failed_grant_leaves_the_gate_denying_without_a_revocation_error() {
        let s = settings()
        setRootWritable(false)
        s.enabled = true

        XCTAssertFalse(MCPAccessGate.isEnabled(root: root))
        XCTAssertNotNil(s.mirrorError, "the user should know the preference didn't save")
        XCTAssertFalse(s.revocationFailed, "nothing was being revoked")
    }

    // MARK: - Consent is necessary but not sufficient

    /// A store the helper can't locate means it would read a stale one, so
    /// consent must not be mirrored as access.
    func test_undiscoverable_store_closes_the_gate_despite_consent() {
        let s = settings(storeIsDiscoverable: { false })
        s.enabled = true

        XCTAssertTrue(s.enabled, "the user's choice is theirs and stays recorded")
        XCTAssertTrue(s.storeUnreachable)
        XCTAssertFalse(MCPAccessGate.isEnabled(root: root),
                       "answering from a stale store is worse than not answering")
    }

    /// And readiness can never grant access nobody asked for.
    func test_discoverable_store_does_not_grant_access_on_its_own() {
        let s = settings(storeIsDiscoverable: { true })
        XCTAssertFalse(s.enabled)
        XCTAssertFalse(MCPAccessGate.isEnabled(root: root))
        XCTAssertFalse(s.storeUnreachable)
    }

    /// `refreshMirror` is how a mid-session relocation reaches the gate
    /// without waiting for a relaunch or a toggle.
    func test_refresh_mirror_reopens_the_gate_when_the_store_comes_back() {
        var discoverable = false
        let s = settings(storeIsDiscoverable: { discoverable })
        s.enabled = true
        XCTAssertFalse(MCPAccessGate.isEnabled(root: root))

        discoverable = true
        s.refreshMirror()

        XCTAssertTrue(MCPAccessGate.isEnabled(root: root))
        XCTAssertFalse(s.storeUnreachable)
    }
}
