import XCTest
import MilaKit
@testable import Mila

/// REGRESSION (CodeRabbit on #183, Major — "keep `store-location.json`
/// synchronized after relocation failures"):
///
/// `relocateRecordings(to:)` switches `recordingsDirectory` and `storeURL`
/// before the pointer is written, and relocation deliberately leaves the old
/// store on disk. If the pointer write then fails, the app carries on using
/// the new store while `store-location.json` still names the old one — so
/// `MilaStoreReader` finds it and mila-mcp answers questions from a store the
/// app has stopped writing to. Confidently wrong, with no signal to the user.
/// The old code only logged the write failure.
///
/// The relocation itself is NOT rolled back, deliberately: the user's choice
/// is persisted upstream (`storage.setDirectory(url)` runs before
/// `relocateRecordings` in `StorageSettingsTab`, and `MilaApp.init` re-applies
/// it on every launch), so a rollback inside the store would not converge —
/// it would leave the store pointing one way and the persisted preference the
/// other, and the next launch would relocate again anyway. Instead the
/// relocation stands and MCP access goes unavailable until a pointer matching
/// the active store has been written and verified.
///
/// The failure is injected by making the app-support root read-only, which is
/// the real shape of the bug (the pointer is written to the ORIGINAL root, not
/// to the newly chosen directory — so this failure is never "the user picked a
/// bad folder").
@MainActor
final class StoreLocationPointerFailureTests: XCTestCase {

    private var root: URL!
    private var relocated: URL!
    private var store: RecordingStore!
    private let suite = "StoreLocationPointerFailureTests.mcp"

    override func setUp() async throws {
        try await super.setUp()
        root = TestSupport.makeTempRoot(label: "StoreLocationPointerFailureTests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        relocated = root.appendingPathComponent("Relocated", isDirectory: true)
        try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: true)
        UserDefaults().removePersistentDomain(forName: suite)
        // Constructed while the root is still writable, so the store starts
        // from a healthy, discoverable state.
        store = RecordingStore(rootDirectory: root)
        XCTAssertTrue(store.storeLocationIsDiscoverable)
    }

    override func tearDown() async throws {
        // Always restore write permission, or the temp tree can't be removed.
        setRootWritable(true)
        if let root { try? FileManager.default.removeItem(at: root) }
        UserDefaults().removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    /// The pointer lives at the ORIGINAL root, so revoking write permission
    /// there is what makes `pointer.write` fail — without touching the
    /// relocated directory the app is now using.
    private func setRootWritable(_ writable: Bool) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o500], ofItemAtPath: root.path)
    }

    private func readerResolvesActiveStore() -> Bool {
        MilaStoreReader.resolvesActiveStore(root: root,
                                            recordingsDirectory: store.recordingsDirectory,
                                            storeFile: store.storeURL)
    }

    private func mcpSettings() -> MCPAccessSettings {
        let settings = MCPAccessSettings(
            defaults: UserDefaults(suiteName: suite)!,
            root: root,
            storeIsDiscoverable: { [weak store] in store?.storeLocationIsDiscoverable ?? true })
        store.onStoreLocationDiscoverabilityChanged = { [weak settings] in
            settings?.refreshMirror()
        }
        return settings
    }

    // MARK: -

    func test_relocation_with_a_failed_pointer_write_is_not_discoverable() {
        var hookFired = 0
        store.onStoreLocationDiscoverabilityChanged = { hookFired += 1 }

        setRootWritable(false)
        store.relocateRecordings(to: relocated)

        XCTAssertFalse(store.storeLocationIsDiscoverable,
                       "a pointer that couldn't be written must not be reported as current")
        XCTAssertEqual(hookFired, 1, "the flip must notify, so the MCP gate can follow immediately")
        XCTAssertFalse(readerResolvesActiveStore(),
                       "precondition: an external reader really would land on the old store")
    }

    /// A successful relocation must behave exactly as it does today.
    func test_successful_relocation_stays_discoverable_and_does_not_notify() {
        var hookFired = 0
        store.onStoreLocationDiscoverabilityChanged = { hookFired += 1 }

        store.relocateRecordings(to: relocated)

        XCTAssertTrue(store.storeLocationIsDiscoverable)
        XCTAssertEqual(hookFired, 0, "no flip, so nothing to notify — the gate file isn't rewritten")
        XCTAssertTrue(readerResolvesActiveStore())
        XCTAssertEqual(MilaStoreReader.resolvedLocation(root: root).storeFileURL
            .resolvingSymlinksInPath().path,
                       store.storeURL.resolvingSymlinksInPath().path)
    }

    /// Consent on + store not discoverable must mirror a CLOSED gate, so the
    /// helper refuses rather than answering from the old store. The mirror is
    /// written after permissions are restored, to prove the gate is closed by
    /// the readiness logic and not merely by the same disk failure.
    func test_mcp_gate_is_closed_while_the_store_is_not_discoverable() throws {
        setRootWritable(false)
        store.relocateRecordings(to: relocated)
        setRootWritable(true)

        let settings = mcpSettings()
        settings.enabled = true

        XCTAssertTrue(settings.enabled, "the user's consent is theirs and must not be silently flipped")
        XCTAssertTrue(settings.storeUnreachable, "the UI needs a signal for a refusal the toggle can't explain")
        XCTAssertNil(settings.mirrorError, "the gate file itself wrote fine — this isn't a save failure")
        XCTAssertFalse(MCPAccessGate.isEnabled(root: root),
                       "the helper must refuse while the pointer doesn't describe the active store")
    }

    /// Convergence: the pointer is rewritten on every launch, so a transient
    /// failure clears itself and access comes back with no user action. Here
    /// the second relocation stands in for that rewrite.
    func test_access_returns_once_a_verified_pointer_is_written() throws {
        setRootWritable(false)
        store.relocateRecordings(to: relocated)

        let settings = mcpSettings()
        settings.enabled = true
        setRootWritable(true)
        XCTAssertFalse(MCPAccessGate.isEnabled(root: root))

        // The root is writable again; the next pointer write succeeds and the
        // hook re-opens the gate.
        store.relocateRecordings(to: relocated)

        XCTAssertTrue(store.storeLocationIsDiscoverable)
        XCTAssertFalse(settings.storeUnreachable)
        XCTAssertTrue(MCPAccessGate.isEnabled(root: root),
                      "access must return on its own once the pointer is verifiable")
        XCTAssertTrue(readerResolvesActiveStore())
    }

    /// Consent OFF plus an undiscoverable store is still just "off" — the
    /// readiness check must not be able to turn access ON.
    func test_readiness_cannot_grant_access_the_user_never_gave() throws {
        setRootWritable(false)
        store.relocateRecordings(to: relocated)
        setRootWritable(true)

        let settings = mcpSettings()
        settings.enabled = false

        XCTAssertFalse(settings.storeUnreachable, "not reachable, but nothing is being refused either")
        XCTAssertFalse(MCPAccessGate.isEnabled(root: root))
    }
}
