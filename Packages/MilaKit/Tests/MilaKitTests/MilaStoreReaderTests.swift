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

    /// Every sidecar read one reader performed, in order.
    ///
    /// The cost #201 is about — a `.txt` read per recording per search — is
    /// invisible in the results: a read whose text is discarded changes
    /// nothing a caller can assert on. Counting the reads is the only way an
    /// assertion can tell the bounded search from the exhaustive one.
    ///
    /// `@unchecked Sendable` + a lock because `MilaStoreReader.SidecarReader`
    /// is `@Sendable` and so may only capture `Sendable` values; the tests
    /// below all drive it from one thread.
    private final class SidecarReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        var count: Int { read { $0.count } }
        var fileNames: [String] { read { $0.map(\.lastPathComponent) } }

        func record(_ url: URL) {
            lock.lock()
            defer { lock.unlock() }
            urls.append(url)
        }

        private func read<T>(_ body: ([URL]) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(urls)
        }
    }

    /// Every transcript one reader rendered, in order.
    ///
    /// The waste #241 is about is invisible for the same reason #201's was:
    /// a transcript that is rendered, scanned and discarded produces exactly
    /// the results a returned one does. Counting the renders is the only way
    /// an assertion can tell "scored every candidate" from "rendered every
    /// candidate".
    private final class RenderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var titles: [String] = []

        var count: Int { read { $0.count } }
        var recordingTitles: [String] { read { $0 } }

        func record(_ title: String) {
            lock.lock()
            defer { lock.unlock() }
            titles.append(title)
        }

        private func read<T>(_ body: ([String]) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(titles)
        }
    }

    private func writeStore(_ recordings: [StoredRecording],
                            recordingsDir: URL? = nil,
                            storeFile: URL? = nil,
                            sidecarReads log: SidecarReadLog? = nil,
                            renders renderLog: RenderLog? = nil) throws -> MilaStoreReader {
        let recsDir = recordingsDir ?? root.appendingPathComponent("Recordings", isDirectory: true)
        let store = storeFile ?? root.appendingPathComponent("recordings.json")
        try FileManager.default.createDirectory(at: recsDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(recordings).write(to: store)
        guard log != nil || renderLog != nil else {
            return MilaStoreReader(recordingsDirectory: recsDir, storeFileURL: store)
        }
        // Counts, then does the real thing — the reader under test still
        // sees exactly what production sees.
        return MilaStoreReader(
            recordingsDirectory: recsDir, storeFileURL: store,
            readSidecar: { url in
                log?.record(url)
                return MilaStoreReader.readSidecarFromDisk(url)
            },
            renderTranscript: { recording, reader in
                renderLog?.record(recording.title)
                return MilaStoreReader.renderNamedTranscript(recording, reader)
            })
    }

    /// Writes the `.txt` sidecar the app keeps beside the audio file.
    private func writeSidecar(_ text: String, for recording: StoredRecording,
                              in reader: MilaStoreReader) throws {
        try text.write(to: reader.recordingsDirectory
            .appendingPathComponent(recording.transcriptFileName),
                       atomically: true, encoding: .utf8)
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

    // MARK: - What a search costs (#201)

    /// NEGATIVE CONTROL. A diarized recording's named transcript is rendered
    /// from segments that `recordings.json` already handed over; its `.txt`
    /// sidecar is not part of that rendering at all. The fallback expression
    /// was nonetheless evaluated EAGERLY, so every recording a search touched
    /// cost one file read whose text was thrown away — the "N synchronous
    /// file reads" of #201, unobservable in the output because the results
    /// were always right, just paid for twice.
    ///
    /// Against the unfixed reader this asserts 0 and gets 20.
    func test_search_reads_no_sidecars_for_diarized_recordings() throws {
        let log = SidecarReadLog()
        let recordings = (0..<20).map {
            rec("Meeting \($0)", daysAgo: Double($0), segments: johnSegments())
        }
        let reader = try writeStore(recordings, sidecarReads: log)
        for recording in recordings {
            try writeSidecar("hello team", for: recording, in: reader)
        }

        XCTAssertEqual(try reader.searchTranscripts(query: "hello", limit: 20).count, 20,
                       "precondition: every recording matches, so none is skipped by luck")
        XCTAssertEqual(log.count, 0,
                       "a diarized transcript renders from segments already in memory — "
                       + "opening its sidecar is work with no observable effect")
    }

    /// The same waste on the `get_transcript` path, pinned separately from
    /// search so a change to the search loop cannot hide a regression here.
    func test_named_transcript_does_not_read_the_sidecar_it_would_discard() throws {
        let log = SidecarReadLog()
        let diarized = rec("Diarized", daysAgo: 0, segments: johnSegments())
        let plain = rec("Plain", daysAgo: 1)
        let reader = try writeStore([diarized, plain], sidecarReads: log)
        try writeSidecar("discarded", for: diarized, in: reader)
        try writeSidecar("used", for: plain, in: reader)

        XCTAssertEqual(reader.namedTranscript(for: diarized),
                       "SPEAKER_00: hello team\nSPEAKER_01: hi, thanks for joining")
        XCTAssertEqual(log.count, 0)
        XCTAssertEqual(reader.namedTranscript(for: plain), "used",
                       "and a recording with no speaker labels still gets its sidecar — "
                       + "there its text is the only transcript there is")
        XCTAssertEqual(log.fileNames, ["Plain.txt"])
    }

    /// The other half of #201: for a recording with no speaker labels the
    /// sidecar read is real work, not waste. Ranking by date does not need to
    /// score the whole store to know the answer, though — date order is the
    /// traversal order — so the scan stops at the `limit`-th hit.
    ///
    /// Against the unfixed reader this asserts 5 and gets 30: it read every
    /// sidecar in the store to return five results.
    func test_date_sorted_search_stops_reading_at_the_limit() throws {
        let log = SidecarReadLog()
        let recordings = (0..<30).map { rec("Note \($0)", daysAgo: Double($0)) }
        let reader = try writeStore(recordings, sidecarReads: log)
        for recording in recordings {
            try writeSidecar("budget review", for: recording, in: reader)
        }

        let hits = try reader.searchTranscripts(query: "budget", sort: .createdAt, limit: 5)
        XCTAssertEqual(hits.map(\.recording.title),
                       ["Note 0", "Note 1", "Note 2", "Note 3", "Note 4"],
                       "the newest five — the same answer the exhaustive scan gave")
        XCTAssertEqual(log.count, 5,
                       "bounded by `limit`, not by the size of the store")
    }

    /// A caller asking for nothing must not pay for the whole store. Both sort
    /// keys used to reach the scan with a cap of zero and throw the work away
    /// in the trailing `prefix(0)`: relevance scored all 20 recordings, and the
    /// date path — whose early stop is only checked *after* a hit is appended —
    /// rendered transcripts up to the first match. The answer was always empty;
    /// the point of this test is that it now costs nothing to produce.
    ///
    /// `limit` reaches the reader `min`-clamped but with no lower bound (see
    /// `MilaMCPToolHandlers`), so a client really can send `limit: 0`.
    func test_a_non_positive_limit_reads_nothing_at_all() throws {
        let log = SidecarReadLog()
        let recordings = (0..<20).map { rec("Note \($0)", daysAgo: Double($0)) }
        let reader = try writeStore(recordings, sidecarReads: log)
        for recording in recordings {
            try writeSidecar("budget review", for: recording, in: reader)
        }

        for sort in [MilaStoreReader.SearchSortKey.relevance, .createdAt] {
            for limit in [0, -5] {
                let hits = try reader.searchTranscripts(query: "budget",
                                                        sort: sort, limit: limit)
                XCTAssertTrue(hits.isEmpty,
                              "sort \(sort.rawValue), limit \(limit)")
            }
        }
        XCTAssertEqual(log.count, 0, "an empty answer costs no reads")
    }

    /// The early stop must be a pure optimisation: a bounded date search has
    /// to return exactly the prefix the unbounded one does, in both
    /// directions, match counts and snippets included.
    func test_bounded_date_search_returns_the_same_prefix_as_the_full_scan() throws {
        let recordings = (0..<8).map { i in
            rec("Sync \(i)", daysAgo: Double(i),
                segments: [.init(start: 0, end: 1, text: "budget \(i)", speaker: "SPEAKER_00")])
        }
        let reader = try writeStore(recordings)
        for order in [MilaStoreReader.SortOrder.desc, .asc] {
            let full = try reader.searchTranscripts(query: "budget", sort: .createdAt,
                                                    order: order, limit: Int.max)
            let bounded = try reader.searchTranscripts(query: "budget", sort: .createdAt,
                                                       order: order, limit: 3)
            XCTAssertEqual(full.count, 8, "order \(order.rawValue)")
            XCTAssertEqual(bounded.map(\.recording.title),
                           Array(full.map(\.recording.title).prefix(3)),
                           "order \(order.rawValue)")
            XCTAssertEqual(bounded.map(\.matchCount),
                           Array(full.map(\.matchCount).prefix(3)),
                           "order \(order.rawValue)")
            XCTAssertEqual(bounded.map(\.snippets),
                           Array(full.map(\.snippets).prefix(3)),
                           "order \(order.rawValue)")
        }
    }

    /// Relevance ranking still scores every candidate, and must: taking the
    /// top few by match count needs all the counts. Pinned over a MIXED
    /// store — one transcript rendered from segments, one that exists only in
    /// its sidecar, one that matches on title alone — so neither the lazy
    /// fallback nor the containment gate can quietly change which text is
    /// searched or how it is counted.
    func test_relevance_ranking_is_unchanged_across_a_mixed_store() throws {
        let diarized = rec("Diarized", daysAgo: 2, segments: [
            .init(start: 0, end: 1, text: "budget budget", speaker: "SPEAKER_00"),
            .init(start: 1, end: 2, text: "and the budget again", speaker: "SPEAKER_01"),
        ])
        let sidecarOnly = rec("Plain", daysAgo: 1)
        let titleOnly = rec("Budget review", daysAgo: 0)
        let reader = try writeStore([diarized, sidecarOnly, titleOnly])
        try writeSidecar("we cut the budget", for: sidecarOnly, in: reader)
        try writeSidecar("nothing relevant here", for: titleOnly, in: reader)

        let hits = try reader.searchTranscripts(query: "budget")
        XCTAssertEqual(hits.map(\.recording.title), ["Diarized", "Budget review", "Plain"],
                       "three matches first by count, then newest-first on the tie")
        XCTAssertEqual(hits.map(\.matchCount), [3, 1, 1])
        XCTAssertEqual(hits.map(\.snippets), [
            ["SPEAKER_00: budget budget\nSPEAKER_01: and the budget again",
             "SPEAKER_00: budget budget\nSPEAKER_01: and the budget again"],
            [],
            ["we cut the budget"],
        ], "a title-only match carries no snippet; the sidecar-only one does")
    }

    /// The containment check is a gate on the per-line pass, never a
    /// replacement for it. A query containing a newline matches the joined
    /// transcript and no single line, so it must still come back as no hit —
    /// the counts a caller sees stay per-line.
    func test_a_query_spanning_a_line_break_still_matches_nothing() throws {
        let recording = rec("Multi", daysAgo: 0, segments: johnSegments())
        let reader = try writeStore([recording])
        XCTAssertEqual(reader.namedTranscript(for: recording),
                       "SPEAKER_00: hello team\nSPEAKER_01: hi, thanks for joining",
                       "precondition: the two turns are on separate lines")
        XCTAssertEqual(try reader.searchTranscripts(query: "team\nSPEAKER_01").count, 0)
    }

    /// The trashed filter lives in `listRecordings`, which produces the
    /// candidates, so search inherits it — and must keep inheriting it: a
    /// trashed recording that matches may neither appear in the results nor
    /// have its transcript opened, whichever ranking or `limit` is in play.
    func test_search_never_reads_or_returns_a_trashed_recording() throws {
        let log = SidecarReadLog()
        let live = rec("Live", daysAgo: 1)
        let trashed = rec("Trashed", daysAgo: 0, deleted: true)
        let reader = try writeStore([live, trashed], sidecarReads: log)
        try writeSidecar("budget talk", for: live, in: reader)
        try writeSidecar("budget talk", for: trashed, in: reader)

        for sort in [MilaStoreReader.SearchSortKey.relevance, .createdAt] {
            let hits = try reader.searchTranscripts(query: "budget", sort: sort, limit: 10)
            XCTAssertEqual(hits.map(\.recording.title), ["Live"], "sort \(sort.rawValue)")
        }
        XCTAssertEqual(log.fileNames, ["Live.txt", "Live.txt"],
                       "a trashed recording's transcript is never opened, let alone returned")
    }

    // MARK: - What relevance ranking costs (#241)

    /// Relevance has to SCORE every candidate. It never had to RENDER every
    /// candidate: a diarized recording's rendered transcript is built out of
    /// segment strings `recordings.json` already handed over, and the query
    /// can be counted against those directly.
    ///
    /// Against the unfixed reader this asserts two renders and gets 23.
    func test_relevance_renders_only_the_transcripts_it_returns() throws {
        let renders = RenderLog()
        let quiet = (0..<20).map { i in
            rec("Sync \(i)", daysAgo: Double(i + 10), segments: [
                .init(start: 0, end: 1, text: "nothing to report", speaker: "SPEAKER_00"),
            ])
        }
        let loud = [
            rec("A", daysAgo: 3, segments: [
                .init(start: 0, end: 1, text: "kafka kafka kafka", speaker: "SPEAKER_00"),
            ]),
            rec("B", daysAgo: 2, segments: [
                .init(start: 0, end: 1, text: "kafka kafka", speaker: "SPEAKER_00"),
            ]),
            rec("C", daysAgo: 1, segments: [
                .init(start: 0, end: 1, text: "kafka", speaker: "SPEAKER_00"),
            ]),
        ]
        let reader = try writeStore(quiet + loud, renders: renders)

        let hits = try reader.searchTranscripts(query: "kafka", limit: 2)
        XCTAssertEqual(hits.map(\.recording.title), ["A", "B"])
        XCTAssertEqual(hits.map(\.matchCount), [3, 2])
        XCTAssertEqual(hits.map(\.snippets), [
            ["SPEAKER_00: kafka kafka kafka"],
            ["SPEAKER_00: kafka kafka"],
        ], "the snippets a rendering is for are still exactly what they were")
        XCTAssertEqual(renders.recordingTitles, ["A", "B"],
                       "23 candidates scored, two returned, two rendered")
    }

    /// The guard against the fix that would have been a regression. Making
    /// relevance cheap by capping the candidate set — scoring the newest few
    /// and stopping — silently loses the best hit in a large store, which is
    /// a worse answer rather than a cheaper one. Here the best hit is the
    /// OLDEST recording, so it is the last thing the traversal reaches: a
    /// cap of any size below the whole store misses it.
    func test_relevance_finds_the_best_hit_when_it_sorts_last_in_traversal() throws {
        let renders = RenderLog()
        var recordings = (0..<40).map { i in
            rec("Note \(i)", daysAgo: Double(i), segments: [
                .init(start: 0, end: 1, text: "budget", speaker: "SPEAKER_00"),
            ])
        }
        recordings.append(rec("Oldest", daysAgo: 99, segments: [
            .init(start: 0, end: 1, text: "budget budget budget budget", speaker: "SPEAKER_00"),
        ]))
        let reader = try writeStore(recordings, renders: renders)

        let hits = try reader.searchTranscripts(query: "budget", limit: 1)
        XCTAssertEqual(hits.map(\.recording.title), ["Oldest"],
                       "every candidate is still scored — the cheap score is over the whole "
                       + "store, not over a prefix of it")
        XCTAssertEqual(hits.first?.matchCount, 4)
        XCTAssertEqual(renders.recordingTitles, ["Oldest"],
                       "and only the winner is rendered")
    }

    /// The count scored from raw segments has to be the count the rendered
    /// transcript would have produced — not close to it. This compares the
    /// two directly over a store built to hit every case the raw scan
    /// reasons about: a turn collapsed out of two segments, an untrimmed
    /// segment, a renamed speaker, a raw `SPEAKER_NN` label, an empty
    /// segment inside a turn, a segment with no speaker, a recording that
    /// lives only in its sidecar, and one whose segments carry no labels at
    /// all.
    func test_scoring_from_raw_segments_agrees_with_the_rendered_count() throws {
        let store: [StoredRecording] = [
            rec("Kickoff", daysAgo: 5, segments: [
                .init(start: 0, end: 1, text: " the quarterly ", speaker: "SPEAKER_00"),
                .init(start: 1, end: 2, text: "budget review ran long", speaker: "SPEAKER_00"),
                .init(start: 2, end: 3, text: "Budget again, and BUDGET", speaker: "SPEAKER_01"),
            ], speakerNames: ["SPEAKER_00": "Daniel"]),
            rec("Budget sync", daysAgo: 4, segments: [
                .init(start: 0, end: 1, text: "café résumé", speaker: "SPEAKER_01"),
                .init(start: 1, end: 2, text: "", speaker: "SPEAKER_01"),
                .init(start: 2, end: 3, text: "nothing else", speaker: nil),
            ]),
            rec("Plain", daysAgo: 3),
            rec("Legacy", daysAgo: 2, segments: [
                .init(start: 0, end: 1, text: "no speaker here"),
            ]),
        ]
        let reader = try writeStore(store)
        try writeSidecar("the budget\nline two mentions budget", for: store[2], in: reader)

        let queries = ["budget", "BUDGET", "quarterly budget", "budget review",
                       "Daniel", "Daniel:", "SPEAKER_01", "cafe", "resume",
                       "the quarterly budget review", "  ", "zzz"]
        for query in queries {
            var expected: [String: Int] = [:]
            for recording in store {
                let count = renderedMatchCount(of: query, for: recording, in: reader)
                if count > 0 { expected[recording.title] = count }
            }
            let hits = try reader.searchTranscripts(query: query, limit: Int.max)
            var actual: [String: Int] = [:]
            for hit in hits { actual[hit.recording.title] = hit.matchCount }
            XCTAssertEqual(actual, expected, "query \(query.debugDescription)")
        }
    }

    /// The raw segment scan may rule a recording IN but never OUT by
    /// mistake. A phrase can exist only across the space the renderer puts
    /// between two segments of one turn, so a query containing whitespace
    /// gets no exact count from the raw scan — the longest whitespace-free
    /// run of it is used to rule out, and here that run is present, so the
    /// transcript is rendered and counted as before.
    func test_a_phrase_query_straddling_two_segments_is_still_found() throws {
        let renders = RenderLog()
        let recording = rec("Sync", daysAgo: 0, segments: [
            .init(start: 0, end: 1, text: "we agreed the quarterly", speaker: "SPEAKER_00"),
            .init(start: 1, end: 2, text: "budget is frozen", speaker: "SPEAKER_00"),
        ])
        let reader = try writeStore([recording], renders: renders)
        XCTAssertEqual(reader.namedTranscript(for: recording),
                       "SPEAKER_00: we agreed the quarterly budget is frozen",
                       "precondition: the two segments collapse into one line")

        let hits = try reader.searchTranscripts(query: "quarterly budget")
        XCTAssertEqual(hits.map(\.matchCount), [1],
                       "the phrase exists nowhere in the segments, only in the rendering")
        XCTAssertEqual(renders.count, 1)
    }

    /// The other thing the raw segments cannot count: a speaker label is
    /// part of every line of that speaker's turns, so it is counted once per
    /// TURN, and the flat segment list does not describe turns. A query that
    /// a label carries is handed back to the renderer.
    func test_a_query_matching_a_speaker_label_is_still_counted_per_turn() throws {
        let renders = RenderLog()
        let recording = rec("Standup", daysAgo: 0, segments: [
            .init(start: 0, end: 1, text: "morning", speaker: "SPEAKER_00"),
            .init(start: 1, end: 2, text: "morning", speaker: "SPEAKER_01"),
            .init(start: 2, end: 3, text: "anything blocking?", speaker: "SPEAKER_00"),
        ], speakerNames: ["SPEAKER_00": "Daniel"])
        let reader = try writeStore([recording], renders: renders)
        XCTAssertEqual(reader.namedTranscript(for: recording),
                       "Daniel: morning\nSPEAKER_01: morning\nDaniel: anything blocking?",
                       "precondition: Daniel speaks two of the three turns")

        XCTAssertEqual(try reader.searchTranscripts(query: "Daniel").map(\.matchCount), [2])
        XCTAssertEqual(renders.count, 1)
    }

    /// A title-only match needs no transcript: the raw scan already proved
    /// nothing in the text matches, so there is no snippet to build and
    /// nothing to render — not even for a hit that IS returned.
    func test_a_title_only_match_renders_nothing() throws {
        let renders = RenderLog()
        let recording = rec("Kafka migration", daysAgo: 0, segments: [
            .init(start: 0, end: 1, text: "nothing to report", speaker: "SPEAKER_00"),
        ])
        let reader = try writeStore([recording], renders: renders)

        let hits = try reader.searchTranscripts(query: "kafka")
        XCTAssertEqual(hits.map(\.matchCount), [1])
        XCTAssertEqual(hits.map(\.snippets), [[]])
        XCTAssertEqual(renders.count, 0)
    }

    /// Independent oracle for `test_scoring_from_raw_segments_agrees_…`: the
    /// count `searchTranscripts` produced before #241 — per line, over the
    /// rendered transcript, plus the title.
    private func renderedMatchCount(of query: String, for recording: StoredRecording,
                                    in reader: MilaStoreReader) -> Int {
        func count(_ needle: String, _ haystack: String) -> Int {
            guard !needle.isEmpty else { return 0 }
            var found = 0
            var range = haystack.startIndex..<haystack.endIndex
            while let match = haystack.range(of: needle,
                                             options: [.caseInsensitive, .diacriticInsensitive],
                                             range: range) {
                found += 1
                range = match.upperBound..<haystack.endIndex
            }
            return found
        }
        var total = count(query, recording.title)
        for line in reader.namedTranscript(for: recording).components(separatedBy: .newlines) {
            total += count(query, line)
        }
        return total
    }
}
