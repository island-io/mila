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
}
