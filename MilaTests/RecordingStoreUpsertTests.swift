import XCTest
@testable import Mila

@MainActor
final class RecordingStoreUpsertTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = TestSupport.makeTempRoot(label: "RecordingStoreUpsertTests")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func recording(_ title: String, at seconds: TimeInterval, id: UUID = UUID()) -> Recording {
        Recording(id: id, title: title, createdAt: Date(timeIntervalSince1970: seconds),
                  source: .microphone, audioFileName: "\(title).wav", status: .completed,
                  fullText: "text of \(title)")
    }

    func test_upsert_inserts_by_creation_date_into_a_newest_first_list() {
        let store = RecordingStore(rootDirectory: root)
        store.add(recording("old", at: 100))
        store.add(recording("new", at: 300))
        XCTAssertEqual(store.recordings.map(\.title), ["new", "old"])

        XCTAssertTrue(store.upsertImported(recording("middle", at: 200)))
        XCTAssertEqual(store.recordings.map(\.title), ["new", "middle", "old"])
        XCTAssertTrue(store.upsertImported(recording("newest", at: 400)))
        XCTAssertTrue(store.upsertImported(recording("oldest", at: 50)))
        XCTAssertEqual(store.recordings.map(\.title), ["newest", "new", "middle", "old", "oldest"])
    }

    func test_upsert_replaces_in_place_by_id_and_never_duplicates() {
        let store = RecordingStore(rootDirectory: root)
        let id = UUID()
        store.add(recording("first", at: 100, id: id))
        store.add(recording("other", at: 200))

        XCTAssertTrue(store.upsertImported(recording("replaced", at: 100, id: id)))
        XCTAssertEqual(store.recordings.filter { $0.id == id }.count, 1)
        XCTAssertEqual(store.recordings.map(\.title), ["other", "replaced"])
        XCTAssertEqual(try? String(contentsOf: store.transcriptURL(for: store.recordings[1]), encoding: .utf8),
                       "text of replaced")

        let relaunched = RecordingStore(rootDirectory: root)
        XCTAssertEqual(relaunched.recordings.map(\.title), ["other", "replaced"])
    }

    func test_upsert_reports_failure_when_the_store_cannot_be_written() throws {
        let store = RecordingStore(rootDirectory: root)
        // Make recordings.json a directory so the atomic write cannot land.
        try? FileManager.default.removeItem(at: store.storeURL)
        try FileManager.default.createDirectory(at: store.storeURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: store.storeURL) }
        XCTAssertFalse(store.upsertImported(recording("doomed", at: 100)))
    }
}
