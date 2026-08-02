import XCTest
@testable import Mila

@MainActor
final class SpeakerDirectoryTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaTests-SpeakerDirectory-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        super.tearDown()
    }

    func test_add_trims_and_rejects_empty_input() {
        let dir = SpeakerDirectory(directory: tempRoot)
        XCTAssertEqual(dir.add("  Daniel  "), "Daniel")
        XCTAssertNil(dir.add("   "))
        XCTAssertNil(dir.add(""))
        XCTAssertEqual(dir.names, ["Daniel"])
    }

    func test_add_dedupes_case_insensitively_returning_canonical_spelling() {
        let dir = SpeakerDirectory(directory: tempRoot)
        XCTAssertEqual(dir.add("Daniel"), "Daniel")
        // Re-adding with different casing must NOT create a duplicate and
        // must hand back the existing spelling — the picker relies on this
        // to land typed names on the canonical entry.
        XCTAssertEqual(dir.add("daniel"), "Daniel")
        XCTAssertEqual(dir.names, ["Daniel"])
    }

    func test_names_stay_sorted() {
        let dir = SpeakerDirectory(directory: tempRoot)
        dir.add("noa")
        dir.add("Avi")
        dir.add("dana")
        XCTAssertEqual(dir.names, ["Avi", "dana", "noa"])
    }

    func test_remove_deletes_case_insensitively() {
        let dir = SpeakerDirectory(directory: tempRoot)
        dir.add("Daniel")
        dir.remove("DANIEL")
        XCTAssertTrue(dir.names.isEmpty)
    }

    func test_matches_filters_case_insensitively_and_empty_query_returns_all() {
        let dir = SpeakerDirectory(directory: tempRoot)
        dir.add("Daniel")
        dir.add("Dana")
        dir.add("Noa")
        XCTAssertEqual(dir.matches(for: "da"), ["Dana", "Daniel"])
        XCTAssertEqual(dir.matches(for: "  "), ["Dana", "Daniel", "Noa"])
        XCTAssertEqual(dir.matches(for: "zzz"), [])
    }

    func test_names_persist_across_instances() {
        let first = SpeakerDirectory(directory: tempRoot)
        first.add("Daniel")
        first.add("Noa")

        let second = SpeakerDirectory(directory: tempRoot)
        XCTAssertEqual(second.names, ["Daniel", "Noa"])

        second.remove("Daniel")
        let third = SpeakerDirectory(directory: tempRoot)
        XCTAssertEqual(third.names, ["Noa"])
    }
}
