import XCTest
@testable import MilaKit

final class MilaMCPToolHandlersTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPHandlerTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Recordings", isDirectory: true),
            withIntermediateDirectories: true)
        // Every test below exercises the granted path, so open the gate the
        // same way the app does — through the real file — rather than by
        // injecting a stub. `test_tools_are_refused_when_access_is_disabled`
        // covers the closed path.
        try MCPAccessGate.set(true, root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func handlers(now: Date = Date()) -> MilaMCPToolHandlers {
        MilaMCPToolHandlers(root: root, now: { now })
    }

    private func call(_ tool: String, _ args: [String: Any] = [:],
                      now: Date = Date()) throws -> [String: Any] {
        let raw = try handlers(now: now).handle(tool: tool, arguments: args)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    private func seedStore(_ recordings: [StoredRecording]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(recordings)
            .write(to: root.appendingPathComponent("recordings.json"))
    }

    private func meeting(_ title: String, daysAgo: Double,
                         speakerNames: [String: String] = [:],
                         summary: String? = nil) -> StoredRecording {
        StoredRecording(title: title,
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400),
                        duration: 300, source: "meeting",
                        audioFileName: "\(title).wav", status: "completed",
                        segments: [
                            .init(start: 0, end: 3, text: "shalom everyone", speaker: "SPEAKER_00"),
                            .init(start: 3, end: 6, text: "let's begin", speaker: "SPEAKER_01"),
                        ],
                        summary: summary, speakerNames: speakerNames)
    }

    private func liveSnapshot(sessionID: UUID = UUID(), state: LiveTranscriptSnapshot.State = .recording,
                              revision: Int = 3, liveAvailable: Bool = true,
                              updatedAt: Date = Date(),
                              segments: [LiveTranscriptSnapshot.Segment]? = nil,
                              finalRecordingID: UUID? = nil) throws -> LiveTranscriptSnapshot {
        let snap = LiveTranscriptSnapshot(
            sessionID: sessionID, state: state, liveTranscriptAvailable: liveAvailable,
            recordingStartedAt: updatedAt.addingTimeInterval(-120), updatedAt: updatedAt,
            revision: revision,
            segments: segments ?? [
                .init(start: 0, end: 2, text: "first", speaker: "SPEAKER_00"),
                .init(start: 2, end: 4, text: "second", speaker: "SPEAKER_00"),
                .init(start: 4, end: 6, text: "third", speaker: "SPEAKER_01"),
            ],
            speakerNames: ["SPEAKER_00": "Dana"],
            finalRecordingID: finalRecordingID)
        try snap.write(root: root)
        return snap
    }

    // MARK: - Hostile cursor input

    /// `since_segment_index` is unvalidated client input. The cursor used to
    /// compute `index - 1` before clamping, which **traps on `Int.min`**
    /// (arithmetic overflow — the subscript itself was always fine, since
    /// `segments[endIndex...]` is a legal empty slice). A tool call must
    /// never be able to kill the server.
    func test_live_transcript_survives_extreme_segment_cursors() throws {
        let session = UUID()
        _ = try liveSnapshot(sessionID: session)
        for cursor in [Int.min, -1, 0, 1, 3, 4, 9_999, Int.max] {
            XCTAssertNoThrow(
                try call("get_live_transcript",
                         ["session_id": session.uuidString,
                          "since_segment_index": cursor]),
                "since_segment_index \(cursor) must be handled, not trapped")
        }
    }

    /// Clamping must not change what a legitimate cursor returns: the
    /// previously-seen segment is re-sent because live merges rewrite it.
    func test_segment_cursor_still_resends_the_last_seen_segment() throws {
        let snapshot = try liveSnapshot()
        XCTAssertEqual(snapshot.segments(sinceIndex: 0).count, 3)
        XCTAssertEqual(snapshot.segments(sinceIndex: 2).map(\.text), ["second", "third"],
                       "A client holding 2 segments re-reads the 2nd, which may have been rewritten.")
        XCTAssertEqual(snapshot.segments(sinceIndex: 3).map(\.text), ["third"])
        XCTAssertEqual(snapshot.segments(sinceIndex: 4), [],
                       "A cursor past the end means the client is up to date — send nothing, "
                       + "and do not re-send the tail.")
        XCTAssertEqual(snapshot.segments(sinceIndex: Int.max), [])
        XCTAssertEqual(snapshot.segments(sinceIndex: Int.min).count, 3,
                       "A nonsense cursor should read as \"from the start\", not crash.")
    }

    // MARK: - list / get / search via raw JSON args

    func test_list_recordings_speaker_filter_and_shape() throws {
        try seedStore([
            meeting("With John", daysAgo: 1, speakerNames: ["SPEAKER_01": "John Doe"]),
            meeting("Other", daysAgo: 0),
        ])
        let result = try call("list_recordings", ["speaker": "john", "limit": 5])
        XCTAssertEqual(result["count"] as? Int, 1)
        let first = try XCTUnwrap((result["recordings"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["title"] as? String, "With John")
        XCTAssertEqual(first["speakers"] as? [String], ["SPEAKER_00", "John Doe"])
        XCTAssertEqual(first["has_summary"] as? Bool, false)
    }

    func test_list_recordings_rejects_bad_sort_and_date() throws {
        try seedStore([meeting("A", daysAgo: 0)])
        XCTAssertThrowsError(try call("list_recordings", ["sort": "bogus"]))
        XCTAssertThrowsError(try call("list_recordings", ["after": "not-a-date"]))
    }

    func test_get_transcript_latest_with_names_and_summary() throws {
        try seedStore([
            meeting("Latest", daysAgo: 0,
                    speakerNames: ["SPEAKER_00": "Dana", "SPEAKER_01": "John Doe"],
                    summary: "Quick sync."),
            meeting("Older", daysAgo: 2),
        ])
        let result = try call("get_transcript")
        XCTAssertEqual(result["title"] as? String, "Latest")
        XCTAssertEqual(result["transcript"] as? String,
                       "Dana: shalom everyone\nJohn Doe: let's begin")
        XCTAssertEqual(result["summary"] as? String, "Quick sync.")
    }

    func test_get_transcript_max_chars_truncates() throws {
        try seedStore([meeting("Long", daysAgo: 0)])
        let result = try call("get_transcript", ["max_chars": 10])
        XCTAssertEqual((result["transcript"] as? String)?.count, 10)
        XCTAssertEqual(result["transcript_truncated"] as? Bool, true)
    }

    func test_get_transcript_unknown_id_throws_not_found() throws {
        try seedStore([meeting("A", daysAgo: 0)])
        XCTAssertThrowsError(try call("get_transcript", ["id": UUID().uuidString]))
        XCTAssertThrowsError(try call("get_transcript", ["id": "not-a-uuid"]))
    }

    func test_search_requires_query() throws {
        try seedStore([meeting("A", daysAgo: 0)])
        XCTAssertThrowsError(try call("search_transcripts"))
        let result = try call("search_transcripts", ["query": "begin"])
        XCTAssertEqual(result["count"] as? Int, 1)
    }

    func test_unknown_tool_throws() {
        XCTAssertThrowsError(try call("bogus_tool"))
    }

    // MARK: - get_live_transcript

    func test_live_no_snapshot_is_not_recording() throws {
        XCTAssertEqual(try call("get_live_transcript")["status"] as? String, "not_recording")
    }

    func test_live_first_poll_returns_full_transcript_and_cursor() throws {
        let snap = try liveSnapshot()
        let result = try call("get_live_transcript")
        XCTAssertEqual(result["status"] as? String, "recording")
        XCTAssertEqual(result["session_id"] as? String, snap.sessionID.uuidString)
        XCTAssertEqual(result["revision"] as? Int, 3)
        XCTAssertEqual(result["next_segment_index"] as? Int, 3)
        XCTAssertEqual((result["new_segments"] as? [[String: Any]])?.count, 3)
        XCTAssertEqual(result["transcript"] as? String,
                       "Dana: first second\nSPEAKER_01: third")
    }

    func test_live_same_revision_short_circuits() throws {
        let snap = try liveSnapshot(revision: 3)
        let result = try call("get_live_transcript", [
            "session_id": snap.sessionID.uuidString,
            "since_revision": 3,
        ])
        XCTAssertEqual(result["changed"] as? Bool, false)
        XCTAssertNil(result["new_segments"])
    }

    func test_live_delta_resends_last_seen_segment() throws {
        let snap = try liveSnapshot(revision: 4)
        // Client saw 2 segments; snapshot now has 3 → resend segment 2 + new segment 3.
        let result = try call("get_live_transcript", [
            "session_id": snap.sessionID.uuidString,
            "since_revision": 2,
            "since_segment_index": 2,
        ])
        XCTAssertEqual(result["changed"] as? Bool, true)
        let texts = (result["new_segments"] as? [[String: Any]])?.compactMap { $0["text"] as? String }
        XCTAssertEqual(texts, ["second", "third"])
        XCTAssertEqual(result["next_segment_index"] as? Int, 3)
    }

    func test_live_session_mismatch_returns_new_session_full_set() throws {
        _ = try liveSnapshot(revision: 3)
        let result = try call("get_live_transcript", [
            "session_id": UUID().uuidString,   // stale cursor from a previous meeting
            "since_revision": 3,
            "since_segment_index": 99,
        ])
        XCTAssertEqual(result["new_session"] as? Bool, true)
        XCTAssertEqual(result["changed"] as? Bool, true)
        XCTAssertEqual((result["new_segments"] as? [[String: Any]])?.count, 3)
        XCTAssertNotNil(result["transcript"])
    }

    func test_live_stale_heartbeat_reports_stale() throws {
        let now = Date()
        _ = try liveSnapshot(updatedAt: now.addingTimeInterval(-60))
        let result = try call("get_live_transcript", now: now)
        XCTAssertEqual(result["status"] as? String, "stale")
    }

    func test_live_gated_hardware_reports_unavailable() throws {
        _ = try liveSnapshot(liveAvailable: false)
        let result = try call("get_live_transcript")
        XCTAssertEqual(result["status"] as? String, "recording_live_unavailable")
    }

    func test_live_completed_hands_off_final_recording_id() throws {
        let finalID = UUID()
        _ = try liveSnapshot(state: .completed, finalRecordingID: finalID)
        let result = try call("get_live_transcript")
        XCTAssertEqual(result["status"] as? String, "completed")
        XCTAssertEqual(result["final_recording_id"] as? String, finalID.uuidString)
    }

    func test_live_interrupted_reports_not_recording_with_hint() throws {
        _ = try liveSnapshot(state: .interrupted)
        let result = try call("get_live_transcript")
        XCTAssertEqual(result["status"] as? String, "not_recording")
        XCTAssertEqual(result["last_session"] as? String, "interrupted")
    }

    // MARK: - The completed → get_transcript handoff

    /// The client-side half of the ordering fix in
    /// `QuickActionsController.stopRecording` (CodeRabbit on #183): the
    /// contract a poller relies on is that the *instant* it sees
    /// `completed`, following `final_recording_id` yields the FINAL
    /// transcript. This walks that handoff the way a client does — poll,
    /// read the id, fetch it — and asserts the fetched text is the final
    /// one, not the pre-drain snapshot the app wrote when it first added
    /// the row.
    ///
    /// The app-side ordering that makes this true (finish the sidecar only
    /// after `store.update`) is pinned separately by
    /// `QuickActionsControllerTests`, which needs the app target.
    func test_completed_handoff_id_resolves_to_the_final_transcript() throws {
        let finalID = UUID()
        var saved = meeting("Handoff", daysAgo: 0)
        saved.id = finalID
        // What the drain wrote LAST: the final segments, not the initial
        // ones the row was created with.
        saved.segments = [
            .init(start: 0, end: 3, text: "shalom everyone", speaker: "SPEAKER_00"),
            .init(start: 3, end: 6, text: "let's begin", speaker: "SPEAKER_01"),
            .init(start: 6, end: 9, text: "and the tail of the meeting", speaker: "SPEAKER_00"),
        ]
        try seedStore([saved])
        _ = try liveSnapshot(state: .completed, finalRecordingID: finalID)

        let poll = try call("get_live_transcript")
        XCTAssertEqual(poll["status"] as? String, "completed")
        let handoff = try XCTUnwrap(poll["final_recording_id"] as? String)

        let fetched = try call("get_transcript", ["id": handoff])
        let transcript = try XCTUnwrap(fetched["transcript"] as? String)
        XCTAssertTrue(transcript.contains("and the tail of the meeting"),
                      "the handoff id must resolve to the FINAL transcript: \(transcript)")
    }

    /// A recording removed during finalization (the user cancels the rename
    /// sheet) closes the sidecar with `completed` and NO id. The refusal
    /// must be the documented "check list_recordings" hint, never an id that
    /// `get_transcript` can only 404 on.
    func test_completed_without_handoff_id_points_at_list_recordings() throws {
        _ = try liveSnapshot(state: .completed, finalRecordingID: nil)
        let result = try call("get_live_transcript")
        XCTAssertEqual(result["status"] as? String, "completed")
        XCTAssertNil(result["final_recording_id"])
        let note = try XCTUnwrap(result["note"] as? String)
        XCTAssertTrue(note.contains("list_recordings"), note)
    }

    // MARK: - ISO 8601 dates

    /// `iso(_:)` moved off `ISO8601DateFormatter` (a non-thread-safe class
    /// that cannot be shared, and cannot be a stored property of a
    /// `Sendable` struct) onto `Date.ISO8601FormatStyle`. The output format
    /// is part of every tool response, so pin that it did not drift.
    func test_created_at_is_rendered_as_internet_date_time_in_utc() throws {
        try seedStore([meeting("Stamped", daysAgo: 0)])
        let result = try call("list_recordings")
        let first = try XCTUnwrap((result["recordings"] as? [[String: Any]])?.first)
        // 1_700_000_000 == 2023-11-14T22:13:20Z
        XCTAssertEqual(first["created_at"] as? String, "2023-11-14T22:13:20Z")
    }

    /// Both input shapes the old formatter accepted still parse: a full
    /// internet date-time, and a bare `yyyy-MM-dd`.
    func test_date_filters_accept_full_timestamps_and_bare_dates() throws {
        try seedStore([meeting("Older", daysAgo: 10), meeting("Newer", daysAgo: 0)])

        let byTimestamp = try call("list_recordings", ["after": "2023-11-10T00:00:00Z"])
        XCTAssertEqual((byTimestamp["recordings"] as? [[String: Any]])?
            .compactMap { $0["title"] as? String }, ["Newer"])

        let byBareDate = try call("list_recordings", ["after": "2023-11-10"])
        XCTAssertEqual((byBareDate["recordings"] as? [[String: Any]])?
            .compactMap { $0["title"] as? String }, ["Newer"])
    }

    /// A fractional-seconds timestamp used to fail the internet-date-time
    /// attempt, fall through to the date-only attempt, and parse as
    /// MIDNIGHT — quietly widening the caller's window by up to a day.
    /// `2023-11-14T22:13:20.500Z` is after the `daysAgo: 0` fixture
    /// (22:13:20Z), so a correct parse excludes it and the old midnight
    /// parse would have let it through.
    func test_fractional_seconds_no_longer_parse_as_midnight() throws {
        try seedStore([meeting("Exactly", daysAgo: 0)])
        let result = try call("list_recordings", ["after": "2023-11-14T22:13:20.500Z"])
        XCTAssertEqual(result["count"] as? Int, 0,
                       "a sub-second-later cursor must exclude the fixture, not fall back to midnight")
    }

    func test_unparseable_date_is_rejected_with_the_offending_value() throws {
        try seedStore([meeting("Any", daysAgo: 0)])
        XCTAssertThrowsError(try call("list_recordings", ["after": "last tuesday"])) { error in
            XCTAssertTrue(String(describing: error).contains("last tuesday"),
                          String(describing: error))
        }
    }
}
