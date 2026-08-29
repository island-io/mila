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

    /// Regression: the comparator used to be `order == .asc ? ascending :
    /// !ascending`, which reports `a < b` *and* `b < a` for equal elements —
    /// not a strict weak ordering, which `sort(by:)` requires. The visible
    /// symptom was that flipping the direction silently reversed tied
    /// elements, so "descending by duration" reordered same-length
    /// recordings for no reason the user could see.
    ///
    /// Direction must only decide how *unequal* elements relate; ties are
    /// untouched by it, so both directions have to agree on their order.
    func test_ties_are_not_reordered_by_flipping_sort_direction() throws {
        let reader = try writeStore([
            rec("first", daysAgo: 1, duration: 60),
            rec("second", daysAgo: 2, duration: 60),
            rec("third", daysAgo: 3, duration: 60),
        ])
        let ascending = try reader.listRecordings(sort: .duration, order: .asc).map(\.title)
        let descending = try reader.listRecordings(sort: .duration, order: .desc).map(\.title)
        XCTAssertEqual(ascending, descending,
                       "All durations are equal, so neither direction may impose an order.")
        XCTAssertEqual(Set(descending), ["first", "second", "third"],
                       "No recording may be dropped or duplicated by the sort.")
    }

    /// Same defect in the search comparator, reached via `sort: .createdAt`
    /// where relevance ties don't mask it.
    func test_search_ties_are_not_reordered_by_flipping_sort_direction() throws {
        let shared = Date(timeIntervalSince1970: 1_700_000_000)
        let reader = try writeStore((0..<3).map { i in
            StoredRecording(title: "Note \(i)", createdAt: shared, duration: 60,
                            source: "meeting", audioFileName: "n\(i).wav",
                            status: "completed",
                            segments: [.init(start: 0, end: 1, text: "budget")])
        })
        let ascending = try reader.searchTranscripts(query: "budget", sort: .createdAt,
                                                     order: .asc).map(\.recording.title)
        let descending = try reader.searchTranscripts(query: "budget", sort: .createdAt,
                                                      order: .desc).map(\.recording.title)
        XCTAssertEqual(ascending, descending)
        XCTAssertEqual(ascending.count, 3)
    }

    /// First run: Mila has never saved a recording, so `recordings.json`
    /// does not exist. The reader must throw rather than pretend the store
    /// is empty — `MilaMCPToolHandlers` turns that throw into the
    /// "Has the Mila app run at least once on this Mac?" message, which is
    /// the only useful thing to tell someone in that state.
    func test_missing_store_file_throws_rather_than_reporting_empty() {
        let empty = root.appendingPathComponent("no-store", isDirectory: true)
        let reader = MilaStoreReader(recordingsDirectory: empty,
                                     storeFileURL: empty.appendingPathComponent("recordings.json"))
        XCTAssertThrowsError(try reader.listRecordings(),
                             "A missing store is not the same as a store with no recordings.")
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

    /// REGRESSION (CodeRabbit on #183): the segment fallback used to be a
    /// separator-free `joined()`, which glued the last word of one segment
    /// to the first word of the next for any recording whose segments came
    /// from the LIVE path — `LiveTranscriber` trims each segment on
    /// construction, so there is no leading space to stand in for the
    /// separator. It read `"hello teamhi, thanks for joining"`.
    func test_transcript_falls_back_to_segments_join() throws {
        let recording = rec("NoSidecar", daysAgo: 0, segments: johnSegments())
        let reader = try writeStore([recording])
        XCTAssertEqual(reader.transcriptText(for: recording),
                       "hello team hi, thanks for joining")
    }

    /// The other half of the same fallback, and the reason a plain
    /// `joined(separator: " ")` is not the fix: whisper's BATCH segments
    /// arrive with a LEADING space, which a space separator would turn into
    /// a double space on every gap.
    func test_transcript_fallback_does_not_double_space_whisper_segments() throws {
        let recording = rec("Whisper", daysAgo: 0, segments: [
            .init(start: 0, end: 2, text: " Hello team", speaker: "SPEAKER_00"),
            .init(start: 2, end: 5, text: " hi, thanks for joining", speaker: "SPEAKER_01"),
        ])
        let reader = try writeStore([recording])
        XCTAssertEqual(reader.transcriptText(for: recording),
                       "Hello team hi, thanks for joining")
    }

    /// Whitespace-only segments (whisper emits them across silence) must
    /// not leave a double space behind either.
    func test_transcript_fallback_drops_whitespace_only_segments() throws {
        let recording = rec("Blanks", daysAgo: 0, segments: [
            .init(start: 0, end: 2, text: "hello team", speaker: "SPEAKER_00"),
            .init(start: 2, end: 3, text: "   ", speaker: "SPEAKER_00"),
            .init(start: 3, end: 5, text: "goodbye", speaker: "SPEAKER_00"),
        ])
        let reader = try writeStore([recording])
        XCTAssertEqual(reader.transcriptText(for: recording), "hello team goodbye")
    }

    // MARK: - Trashed recordings are not reachable by id

    /// REGRESSION (CodeRabbit on #183, CWE-200): `recording(id:)` had no
    /// `isTrashed` filter, so a client holding a UUID cached from an earlier
    /// `list_recordings` could still fetch the transcript of a recording the
    /// user had since moved to the trash — the same store answering "no" to a
    /// listing and "yes" to a direct lookup for the same row.
    func test_direct_id_lookup_excludes_trashed_recordings() throws {
        let live = rec("Live", daysAgo: 1)
        let trashed = rec("Trashed", daysAgo: 0, deleted: true)
        let reader = try writeStore([live, trashed])

        XCTAssertEqual(try reader.listRecordings().map(\.title), ["Live"],
                       "precondition: listing already hides it")
        XCTAssertNotNil(try reader.recording(id: live.id))
        XCTAssertNil(try reader.recording(id: trashed.id),
                     "a retained id must not be a way back into a trashed transcript")
    }

    /// A trashed id and a nonexistent id must be indistinguishable —
    /// answering "trashed" would confirm the recording exists, which is the
    /// same disclosure in a smaller package.
    func test_trashed_and_unknown_ids_are_indistinguishable() throws {
        let trashed = rec("Trashed", daysAgo: 0, deleted: true)
        let reader = try writeStore([trashed])
        XCTAssertNil(try reader.recording(id: trashed.id))
        XCTAssertNil(try reader.recording(id: UUID()))
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
