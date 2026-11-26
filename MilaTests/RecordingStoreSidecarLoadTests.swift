import XCTest
@testable import Mila

/// Launch hydrates every transcript sidecar; the reads run concurrently but
/// the result must be identical to reading them one by one (#410).
@MainActor
final class RecordingStoreSidecarLoadTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaTests-sidecars-\(UUID())", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        super.tearDown()
    }

    func test_readSidecars_preserves_order_and_reports_missing_files_as_nil() throws {
        var urls: [URL] = []
        for i in 0..<64 {
            let url = tempRoot.appendingPathComponent("\(i).txt")
            if i % 5 != 0 { try "text \(i)".write(to: url, atomically: true, encoding: .utf8) }
            urls.append(url)
        }
        let texts = RecordingStore.readSidecars(urls)
        XCTAssertEqual(texts.count, 64)
        for i in 0..<64 {
            XCTAssertEqual(texts[i], i % 5 == 0 ? nil : "text \(i)", "slot \(i)")
        }
    }

    func test_readSidecars_handles_empty_and_single() throws {
        XCTAssertTrue(RecordingStore.readSidecars([]).isEmpty)
        let url = tempRoot.appendingPathComponent("one.txt")
        try "solo".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(RecordingStore.readSidecars([url]), ["solo"])
    }

    func test_relaunch_hydrates_every_transcript() {
        let first = RecordingStore(rootDirectory: tempRoot)
        var expected: [UUID: String] = [:]
        for i in 0..<40 {
            let r = Recording(title: "R\(i)", source: .microphone, audioFileName: "r\(i).wav",
                              status: .completed, fullText: "transcript number \(i)")
            first.add(r)
            expected[r.id] = "transcript number \(i)"
        }
        let relaunched = RecordingStore(rootDirectory: tempRoot)
        XCTAssertEqual(relaunched.recordings.count, 40)
        for r in relaunched.recordings {
            XCTAssertEqual(r.fullText, expected[r.id])
        }
    }
}
