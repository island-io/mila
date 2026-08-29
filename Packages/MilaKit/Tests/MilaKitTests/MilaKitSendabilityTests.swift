import XCTest
@testable import MilaKit

/// The MCP SDK registers `CallTool` with an `@escaping @Sendable` handler
/// closure, and `mila-mcp` captures a `MilaMCPToolHandlers` value into it.
/// That only compiled because the app project is in the Swift 5.10 language
/// mode: the handler held a non-`Sendable` `MilaDataSource` existential and
/// two non-`Sendable` injected closures, so the escaping capture was
/// unchecked (CodeRabbit on #183).
///
/// Two things pin the fix. `MilaKit`'s `Package.swift` turns on full
/// `StrictConcurrency` checking, so a non-`Sendable` field reappearing on
/// any of these types is a compiler diagnostic rather than a silent
/// regression. And the assertions below are compile-time: `requireSendable`
/// is generic over `T: Sendable`, so naming a type that has lost its
/// conformance fails to build. Neither uses `@unchecked Sendable` anywhere —
/// every type in the chain is a value type over `Sendable` storage.
final class MilaKitSendabilityTests: XCTestCase {

    /// Compiles only for a `Sendable` `T`.
    private func requireSendable<T: Sendable>(_: T.Type) {}

    func test_the_whole_data_source_chain_is_sendable() {
        // What the CallTool closure actually captures.
        requireSendable(MilaMCPToolHandlers.self)
        requireSendable((any MilaDataSource).self)
        requireSendable(FileBackedDataSource.self)

        // What the data source reads and returns.
        requireSendable(MilaStoreReader.self)
        requireSendable(MilaStoreReader.Filter.self)
        requireSendable(MilaStoreReader.SortKey.self)
        requireSendable(MilaStoreReader.SortOrder.self)
        requireSendable(MilaStoreReader.SearchSortKey.self)
        requireSendable(MilaStoreReader.SearchHit.self)
        requireSendable(StoredRecording.self)
        requireSendable(StoredRecording.Segment.self)
        requireSendable(StoredRecording.ActionItem.self)
        requireSendable(LiveTranscriptSnapshot.self)
        requireSendable(LiveTranscriptSnapshot.State.self)

        // Cross-process contract files the helper resolves before reading.
        requireSendable(MCPAccessGate.self)
        requireSendable(StoreLocationPointer.self)
    }

    /// The shape `MilaMCPMain` uses: the handler escapes into a `@Sendable`
    /// closure that the SDK may invoke off any thread. Written out here so
    /// the capture is exercised by MilaKit's own strictly-checked build and
    /// not only by the app target's 5.10-mode one.
    func test_handlers_can_be_captured_into_an_escaping_sendable_closure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendabilityTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try MCPAccessGate.set(true, root: root)

        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let recording = StoredRecording(title: "Escaped", createdAt: fixed,
                                        audioFileName: "Escaped.wav",
                                        legacyFullText: "captured and read")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([recording]).write(to: root.appendingPathComponent("recordings.json"))

        let handlers = MilaMCPToolHandlers(root: root, now: { fixed })
        let call: @Sendable (String) throws -> String = { tool in
            try handlers.handle(tool: tool, arguments: [:])
        }

        // Concurrently, from off the caller's thread — the SDK gives no
        // ordering guarantee, and the data source holds only a URL, so
        // parallel calls must simply agree.
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask { try call("get_transcript") }
            }
            for try await result in group {
                XCTAssertTrue(result.contains("captured and read"), result)
            }
        }
    }
}
