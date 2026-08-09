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
}
