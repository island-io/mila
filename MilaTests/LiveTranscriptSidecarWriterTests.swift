import XCTest
import TranscriptionCore
import MilaKit
@testable import Mila

@MainActor
final class LiveTranscriptSidecarWriterTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func snapshot() -> LiveTranscriptSnapshot? {
        LiveTranscriptSnapshot.read(root: root)
    }

    private func segs(_ texts: String...) -> [TranscriptSegment] {
        texts.enumerated().map { i, t in
            TranscriptSegment(start: Double(i), end: Double(i + 1), text: t,
                              speaker: "SPEAKER_00")
        }
    }

    func test_begin_writes_recording_snapshot() throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        writer.begin(title: nil, source: "meeting", liveAvailable: true)
        let snap = try XCTUnwrap(snapshot())
        XCTAssertEqual(snap.state, .recording)
        XCTAssertTrue(snap.liveTranscriptAvailable)
        XCTAssertEqual(snap.revision, 1)
        XCTAssertEqual(snap.source, "meeting")
        XCTAssertTrue(snap.segments.isEmpty)
    }

    func test_update_bumps_revision_and_writes_content() throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        writer.begin(title: nil, source: nil, liveAvailable: true)
        writer.update(segments: segs("hello"), speakerNames: ["SPEAKER_00": "Dana"])
        let snap = try XCTUnwrap(snapshot())
        XCTAssertEqual(snap.revision, 2)
        XCTAssertEqual(snap.segments.map(\.text), ["hello"])
        XCTAssertEqual(snap.speakerNames, ["SPEAKER_00": "Dana"])
    }

    func test_unchanged_update_does_not_bump_revision() throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        writer.begin(title: nil, source: nil, liveAvailable: true)
        writer.update(segments: segs("hello"), speakerNames: [:])
        writer.update(segments: segs("hello"), speakerNames: [:])
        XCTAssertEqual(try XCTUnwrap(snapshot()).revision, 2)
    }

    func test_trailing_write_lands_after_throttle_window() async throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0.15)
        writer.begin(title: nil, source: nil, liveAvailable: true)
        // Two updates inside one throttle window: the second must land via
        // the trailing write, not be dropped.
        writer.update(segments: segs("one"), speakerNames: [:])
        writer.update(segments: segs("one", "two"), speakerNames: [:])
        try await Task.sleep(nanoseconds: 400_000_000)
        let snap = try XCTUnwrap(snapshot())
        XCTAssertEqual(snap.segments.map(\.text), ["one", "two"])
        XCTAssertEqual(snap.revision, 3)
    }

    func test_finish_marks_completed_with_handoff_id_and_stops_updates() throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        writer.begin(title: nil, source: nil, liveAvailable: true)
        writer.update(segments: segs("hello"), speakerNames: [:])
        let recordingID = UUID()
        writer.finish(recordingID: recordingID)

        var snap = try XCTUnwrap(snapshot())
        XCTAssertEqual(snap.state, .completed)
        XCTAssertEqual(snap.finalRecordingID, recordingID)

        // Snapshot stays on disk (poller handoff) and later updates are ignored.
        writer.update(segments: segs("late"), speakerNames: [:])
        snap = try XCTUnwrap(snapshot())
        XCTAssertEqual(snap.state, .completed)
        XCTAssertEqual(snap.segments.map(\.text), ["hello"])
    }

    func test_gated_hardware_snapshot_reports_live_unavailable() throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        writer.begin(title: nil, source: nil, liveAvailable: false)
        XCTAssertFalse(try XCTUnwrap(snapshot()).liveTranscriptAvailable)
    }

    func test_cleanup_at_launch_marks_leftover_recording_interrupted() throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        writer.begin(title: nil, source: nil, liveAvailable: true)
        // Simulate a crash: a fresh writer (new process) finds the stale file.
        let relaunched = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        relaunched.cleanupAtLaunch()
        XCTAssertEqual(try XCTUnwrap(snapshot()).state, .interrupted)
    }

    func test_new_session_gets_fresh_session_id() throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        writer.begin(title: nil, source: nil, liveAvailable: true)
        let first = try XCTUnwrap(snapshot()).sessionID
        writer.finish(recordingID: nil)
        writer.begin(title: nil, source: nil, liveAvailable: true)
        let second = try XCTUnwrap(snapshot()).sessionID
        XCTAssertNotEqual(first, second)
    }
}
