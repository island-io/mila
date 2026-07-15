import XCTest
@testable import MilaKit

final class MilaStoreReaderTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaKitTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func writeStore(_ recordings: [StoredRecording],
                            recordingsDir: URL? = nil,
                            storeFile: URL? = nil) throws -> MilaStoreReader {
        let recsDir = recordingsDir ?? root.appendingPathComponent("Recordings", isDirectory: true)
        let store = storeFile ?? root.appendingPathComponent("recordings.json")
        try FileManager.default.createDirectory(at: recsDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recordings).write(to: store)
        return MilaStoreReader(recordingsDirectory: recsDir, storeFileURL: store)
    }

    private func rec(_ title: String, daysAgo: Double, duration: Double = 60,
                     source: String = "meeting", status: String = "completed",
                     folder: String? = nil, appName: String? = nil,
                     deleted: Bool = false,
                     segments: [StoredRecording.Segment] = [],
                     speakerNames: [String: String] = [:]) -> StoredRecording {
        StoredRecording(title: title,
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400),
                        duration: duration, source: source,
                        audioFileName: "\(title).wav", status: status,
                        segments: segments,
                        deletedAt: deleted ? Date(timeIntervalSince1970: 1_700_000_001) : nil,
                        folder: folder, appName: appName,
                        speakerNames: speakerNames)
    }

    private func johnSegments() -> [StoredRecording.Segment] {
        [.init(start: 0, end: 2, text: "hello team", speaker: "SPEAKER_00"),
         .init(start: 2, end: 5, text: "hi, thanks for joining", speaker: "SPEAKER_01")]
    }

    // MARK: - Pointer resolution

    func test_pointer_resolution_follows_relocated_store() throws {
        let custom = root.appendingPathComponent("Custom", isDirectory: true)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try StoreLocationPointer(recordingsDirectory: custom.path,
                                 storeFile: custom.appendingPathComponent("recordings.json").path,
                                 updatedAt: Date()).write(to: root)

        let reader = MilaStoreReader(root: root)
        XCTAssertEqual(reader.recordingsDirectory.path, custom.path)
        XCTAssertEqual(reader.storeFileURL.lastPathComponent, "recordings.json")
        XCTAssertEqual(reader.storeFileURL.deletingLastPathComponent().path, custom.path)
    }

    func test_missing_pointer_falls_back_to_default_layout() {
        let reader = MilaStoreReader(root: root)
        XCTAssertEqual(reader.recordingsDirectory.path,
                       root.appendingPathComponent("Recordings").path)
        XCTAssertEqual(reader.storeFileURL.path,
                       root.appendingPathComponent("recordings.json").path)
    }

    // MARK: - Listing

    func test_list_excludes_trashed_and_sorts_newest_first() throws {
        let reader = try writeStore([
            rec("Old", daysAgo: 3),
            rec("New", daysAgo: 1),
            rec("Trashed", daysAgo: 0, deleted: true),
        ])
        let listed = try reader.listRecordings()
        XCTAssertEqual(listed.map(\.title), ["New", "Old"])
    }

    func test_speaker_filter_is_case_insensitive_over_display_names() throws {
        let reader = try writeStore([
            rec("With John", daysAgo: 1, segments: johnSegments(),
                speakerNames: ["SPEAKER_01": "John Doe"]),
            rec("Without", daysAgo: 0, segments: johnSegments()),
        ])
        let hits = try reader.listRecordings(filter: .init(speaker: "john doe"))
        XCTAssertEqual(hits.map(\.title), ["With John"])
    }

    func test_source_and_date_filters() throws {
        let reader = try writeStore([
            rec("Mic", daysAgo: 1, source: "microphone"),
            rec("Meeting", daysAgo: 2, source: "meeting"),
        ])
        XCTAssertEqual(try reader.listRecordings(filter: .init(source: "microphone")).map(\.title),
                       ["Mic"])
        let cutoff = Date(timeIntervalSince1970: 1_700_000_000 - 1.5 * 86_400)
        XCTAssertEqual(try reader.listRecordings(filter: .init(after: cutoff)).map(\.title),
                       ["Mic"])
        XCTAssertEqual(try reader.listRecordings(filter: .init(before: cutoff)).map(\.title),
                       ["Meeting"])
    }

    func test_sort_by_duration_and_title_with_order() throws {
        let reader = try writeStore([
            rec("Bravo", daysAgo: 1, duration: 30),
            rec("alpha", daysAgo: 2, duration: 90),
        ])
        XCTAssertEqual(try reader.listRecordings(sort: .duration, order: .desc).map(\.title),
                       ["alpha", "Bravo"])
        XCTAssertEqual(try reader.listRecordings(sort: .title, order: .asc).map(\.title),
                       ["alpha", "Bravo"])
    }

    func test_limit_caps_results() throws {
        let reader = try writeStore((0..<5).map { rec("R\($0)", daysAgo: Double($0)) })
        XCTAssertEqual(try reader.listRecordings(limit: 2).count, 2)
    }

    func test_latest_completed_skips_pending() throws {
        let reader = try writeStore([
            rec("Pending", daysAgo: 0, status: "pending"),
            rec("Done", daysAgo: 1),
        ])
        XCTAssertEqual(try reader.latestCompletedRecording()?.title, "Done")
    }

    // MARK: - Transcript rendering

    func test_transcript_prefers_sidecar_txt() throws {
        let recording = rec("Side", daysAgo: 0, segments: johnSegments())
        let reader = try writeStore([recording])
        try "sidecar text".write(
            to: reader.recordingsDirectory.appendingPathComponent("Side.txt"),
            atomically: true, encoding: .utf8)
        XCTAssertEqual(reader.transcriptText(for: recording), "sidecar text")
    }

    func test_transcript_falls_back_to_segments_join() throws {
        let recording = rec("NoSidecar", daysAgo: 0, segments: johnSegments())
        let reader = try writeStore([recording])
        XCTAssertEqual(reader.transcriptText(for: recording),
                       "hello teamhi, thanks for joining")
    }

    func test_named_transcript_resolves_speaker_names() throws {
        let recording = rec("Named", daysAgo: 0, segments: johnSegments(),
                            speakerNames: ["SPEAKER_00": "Daniel", "SPEAKER_01": "John Doe"])
        let reader = try writeStore([recording])
        XCTAssertEqual(reader.namedTranscript(for: recording),
                       "Daniel: hello team\nJohn Doe: hi, thanks for joining")
    }

    // MARK: - Search

    func test_search_matches_transcript_with_snippets_and_relevance() throws {
        let hitRec = rec("Roadmap", daysAgo: 1, segments: [
            .init(start: 0, end: 1, text: "the roadmap looks solid", speaker: "SPEAKER_00"),
            .init(start: 1, end: 2, text: "ship the roadmap next week", speaker: "SPEAKER_01"),
        ])
        let missRec = rec("Standup", daysAgo: 0, segments: [
            .init(start: 0, end: 1, text: "nothing to report", speaker: "SPEAKER_00"),
        ])
        let reader = try writeStore([hitRec, missRec])
        let hits = try reader.searchTranscripts(query: "roadmap")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.recording.title, "Roadmap")
        // Title match + two transcript matches.
        XCTAssertEqual(hits.first?.matchCount, 3)
        XCTAssertFalse(hits.first?.snippets.isEmpty ?? true)
    }

    func test_search_sort_by_relevance_then_recency() throws {
        let often = rec("Often", daysAgo: 5, segments: [
            .init(start: 0, end: 1, text: "kafka kafka kafka", speaker: "SPEAKER_00"),
        ])
        let once = rec("Once", daysAgo: 0, segments: [
            .init(start: 0, end: 1, text: "kafka maybe", speaker: "SPEAKER_00"),
        ])
        let reader = try writeStore([often, once])
        XCTAssertEqual(try reader.searchTranscripts(query: "kafka").map(\.recording.title),
                       ["Often", "Once"])
        XCTAssertEqual(try reader.searchTranscripts(query: "kafka", sort: .createdAt)
            .map(\.recording.title), ["Once", "Often"])
    }
}
