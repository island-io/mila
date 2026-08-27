import XCTest
@testable import MilaKit

/// The consent gate is the whole of "off by default", so its default answer
/// matters more than any single tool behaviour.
final class MCPAccessGateTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPGateTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func test_access_is_denied_when_no_gate_file_exists() {
        XCTAssertFalse(MCPAccessGate.isEnabled(root: root),
                       "A fresh install has written no gate file and must read as off.")
    }

    func test_access_follows_the_flag_in_both_directions() throws {
        try MCPAccessGate.set(true, root: root)
        XCTAssertTrue(MCPAccessGate.isEnabled(root: root))

        try MCPAccessGate.set(false, root: root)
        XCTAssertFalse(MCPAccessGate.isEnabled(root: root),
                       "Turning the setting back off must revoke access, not just stop granting it.")
    }

    func test_malformed_gate_file_fails_closed() throws {
        try Data("not json".utf8).write(to: MCPAccessGate.url(root: root))
        XCTAssertFalse(MCPAccessGate.isEnabled(root: root),
                       "An unparseable gate must deny, never default to allow.")
    }

    func test_gate_file_lives_beside_the_store_pointer() {
        XCTAssertEqual(MCPAccessGate.url(root: root).lastPathComponent, "mcp-access.json")
        XCTAssertEqual(MCPAccessGate.url(root: root).deletingLastPathComponent(), root,
                       "The helper resolves consent before it resolves the store location, "
                       + "so the gate must sit at the fixed root.")
    }

    // MARK: - The gate as the tool layer sees it

    func test_tools_are_refused_when_access_is_disabled() throws {
        let handlers = MilaMCPToolHandlers(root: root)
        for tool in MilaMCPToolHandlers.toolSpecs.map(\.name) {
            XCTAssertThrowsError(try handlers.handle(tool: tool, arguments: [:]),
                                 "\(tool) must refuse while access is off") { error in
                XCTAssertTrue(error is MCPAccessDisabledError,
                              "\(tool) failed with \(error) instead of the access error")
            }
        }
    }

    func test_refusal_message_names_the_setting_that_unblocks_it() {
        let message = MCPAccessDisabledError().errorDescription ?? ""
        XCTAssertTrue(message.contains("Settings"), "Refusal must say where to turn it on: \(message)")
        XCTAssertTrue(message.contains("Allow MCP access to transcriptions"),
                      "Refusal must name the toggle verbatim: \(message)")
    }

    /// Revoking has to bite an already-running server, which is why the gate
    /// is re-read per call rather than cached at startup.
    func test_revoking_access_takes_effect_without_restarting_the_server() throws {
        try MCPAccessGate.set(true, root: root)
        try Data("[]".utf8).write(to: root.appendingPathComponent("recordings.json"))

        let handlers = MilaMCPToolHandlers(root: root)
        XCTAssertNoThrow(try handlers.handle(tool: "list_recordings", arguments: [:]))

        try MCPAccessGate.set(false, root: root)
        XCTAssertThrowsError(try handlers.handle(tool: "list_recordings", arguments: [:]),
                             "The same handler instance must start refusing once revoked.")
    }

    // MARK: - Revocation must fail closed

    /// REGRESSION (CodeRabbit on #183, CWE-359): revoking used to be a plain
    /// atomic write, and a failed write just propagated. The previous
    /// `enabled: true` file SURVIVED — so the toggle read off in the UI while
    /// a configured MCP client kept reading transcripts, indefinitely and
    /// invisibly. Revocation now judges the END STATE: it escalates to
    /// deleting the file (absence denies) and only throws if access is still
    /// granted afterwards.
    ///
    /// This is the case that separates the new behaviour from the old. The
    /// write is made to fail for a reason removal can fix — a stale
    /// *directory* sitting at the gate's path, which `Data.write` cannot
    /// replace but `removeItem` can clear. Old code: threw, directory intact.
    /// New code: no throw, and the stale entry is gone.
    ///
    /// It stands in for the realistic version of the same shape, a full disk:
    /// the write fails, the removal succeeds, and denial is reached. That one
    /// isn't simulable at unit level.
    func test_revocation_that_cannot_be_written_is_reached_by_removal() throws {
        let gate = MCPAccessGate.url(root: root)
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)

        XCTAssertNoThrow(try MCPAccessGate.set(false, root: root),
                         "denial was achievable, so revocation must report success")
        XCTAssertFalse(MCPAccessGate.isEnabled(root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: gate.path),
                       "the unwritable entry must have been removed — that is the escalation")
    }

    /// And when denial genuinely cannot be reached — here a read-only root
    /// defeats both the atomic write and the removal — `set(false)` must
    /// THROW while access is still granted. That throw is the whole signal
    /// `MCPAccessSettings` relies on to keep the toggle showing ON rather
    /// than claiming an off state it never achieved.
    func test_unachievable_revocation_throws_and_says_so() throws {
        try MCPAccessGate.set(true, root: root)
        XCTAssertTrue(MCPAccessGate.isEnabled(root: root))

        setRootWritable(false)
        defer { setRootWritable(true) }

        XCTAssertThrowsError(try MCPAccessGate.set(false, root: root),
                             "returning normally here would be the silent fail-open")
        XCTAssertTrue(MCPAccessGate.isEnabled(root: root),
                      "precondition: this is the state the caller must be warned about")
    }

    /// The asymmetry is deliberate: failing to publish `enabled: true` leaves
    /// the gate denying, which is safe, so it must NOT be escalated into
    /// deleting a file or reported as a revocation problem.
    func test_failing_to_grant_leaves_the_gate_denying() throws {
        setRootWritable(false)
        defer { setRootWritable(true) }

        XCTAssertThrowsError(try MCPAccessGate.set(true, root: root))
        XCTAssertFalse(MCPAccessGate.isEnabled(root: root),
                       "a grant that couldn't be written must not grant")
    }

    private func setRootWritable(_ writable: Bool) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: writable ? 0o755 : 0o500], ofItemAtPath: root.path)
    }
}
