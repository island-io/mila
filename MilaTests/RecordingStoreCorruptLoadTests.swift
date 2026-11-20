import XCTest
@testable import Mila

/// A `recordings.json` that can't be fully read must never be silently
/// replaced by an emptier file (improvement plan item 1).
@MainActor
final class RecordingStoreCorruptLoadTests: XCTestCase {

    private var tempRoot: URL!
    private var storeFile: URL { tempRoot.appendingPathComponent("recordings.json") }

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaTests-corrupt-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        super.tearDown()
    }

    private func damagedBackups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("recordings.damaged-") }
    }

    func test_missing_file_is_a_clean_start_without_an_issue() {
        let store = RecordingStore(rootDirectory: tempRoot)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertNil(store.libraryLoadIssue)
    }

    func test_truncated_file_is_backed_up_before_the_next_write() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.add(Recording(title: "A", source: .microphone, audioFileName: "a.wav"))
        first.add(Recording(title: "B", source: .microphone, audioFileName: "b.wav"))
        let original = try Data(contentsOf: storeFile)
        try original.prefix(original.count / 2).write(to: storeFile)
        let truncated = try Data(contentsOf: storeFile)

        let relaunched = RecordingStore(rootDirectory: tempRoot)
        XCTAssertEqual(relaunched.libraryLoadIssue?.kind, .undecodable)
        // The next mutation overwrites recordings.json...
        relaunched.add(Recording(title: "C", source: .microphone, audioFileName: "c.wav"))

        // ...but the unreadable bytes survive in the backup.
        let backups = try damagedBackups()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), truncated)
        XCTAssertEqual(relaunched.libraryLoadIssue?.backup?.lastPathComponent,
                       backups[0].lastPathComponent)
    }

    func test_one_bad_row_does_not_drop_the_others() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.add(Recording(title: "Keep 1", source: .microphone, audioFileName: "a.wav"))
        first.add(Recording(title: "Keep 2", source: .microphone, audioFileName: "b.wav"))
        var rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeFile)) as? [[String: Any]])
        rows.append(["id": "not-a-uuid", "title": 42])
        try JSONSerialization.data(withJSONObject: rows).write(to: storeFile)

        let relaunched = RecordingStore(rootDirectory: tempRoot)

        XCTAssertEqual(Set(relaunched.recordings.map(\.title)), ["Keep 1", "Keep 2"])
        XCTAssertEqual(relaunched.libraryLoadIssue?.kind, .rowsDropped)
        XCTAssertEqual(relaunched.libraryLoadIssue?.droppedRows, 1)
        XCTAssertEqual(try damagedBackups().count, 1, "the original with the bad row is kept")
    }

    func test_orphan_audio_is_still_recovered_when_the_file_is_undecodable() throws {
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: storeFile)
        let wav = tempRoot.appendingPathComponent("Recordings/crashed.wav")
        try Data(count: RecordingStore.emptyWAVByteCount + 1).write(to: wav)

        let store = RecordingStore(rootDirectory: tempRoot)

        XCTAssertEqual(store.recordings.map(\.audioFileName), ["crashed.wav"])
        XCTAssertEqual(store.libraryLoadIssue?.kind, .undecodable)
    }

    func test_a_healthy_store_reports_no_issue_and_no_backup() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.add(Recording(title: "A", source: .microphone, audioFileName: "a.wav"))
        let relaunched = RecordingStore(rootDirectory: tempRoot)
        XCTAssertNil(relaunched.libraryLoadIssue)
        XCTAssertTrue(try damagedBackups().isEmpty)
    }
}
