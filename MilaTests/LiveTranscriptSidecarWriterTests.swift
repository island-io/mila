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

    // MARK: - Deferred handoff for a not-yet-final transcript

    /// `transcriptIsFinal: false` means the row is saved but the batch worker
    /// still owes it a transcript, so `final_recording_id` — which the live
    /// tool describes as resolving to the authoritative transcript — must not
    /// be published yet. (CodeRabbit on #183.)
    func test_pending_transcript_closes_without_a_handoff_id() throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        writer.begin(title: nil, source: nil, liveAvailable: true)
        writer.finish(recordingID: UUID(), transcriptIsFinal: false)

        let snap = try XCTUnwrap(snapshot())
        XCTAssertEqual(snap.state, .completed)
        XCTAssertNil(snap.finalRecordingID)
    }

    /// A final transcript still publishes immediately — the default, and the
    /// authoritative-live path.
    func test_final_transcript_publishes_the_handoff_immediately() throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        let id = UUID()
        writer.begin(title: nil, source: nil, liveAvailable: true)
        writer.finish(recordingID: id)

        XCTAssertEqual(try XCTUnwrap(snapshot()).finalRecordingID, id)
    }

    func test_batch_completion_attaches_the_deferred_handoff() throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        let id = UUID()
        writer.begin(title: nil, source: nil, liveAvailable: true)
        writer.finish(recordingID: id, transcriptIsFinal: false)
        let sessionBefore = try XCTUnwrap(snapshot()).sessionID
        let revisionBefore = try XCTUnwrap(snapshot()).revision

        writer.attachHandoff(forRecording: id)

        let snap = try XCTUnwrap(snapshot())
        XCTAssertEqual(snap.finalRecordingID, id)
        XCTAssertEqual(snap.sessionID, sessionBefore, "same snapshot, not a new one")
        XCTAssertGreaterThan(snap.revision, revisionBefore,
                             "a content change must move the poller's cursor")
    }

    /// The completion hook is global and fires for re-transcribes of unrelated
    /// rows, so only the awaited recording may claim the handoff.
    func test_unrelated_completion_does_not_attach() throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        writer.begin(title: nil, source: nil, liveAvailable: true)
        writer.finish(recordingID: UUID(), transcriptIsFinal: false)

        writer.attachHandoff(forRecording: UUID())

        XCTAssertNil(try XCTUnwrap(snapshot()).finalRecordingID)
    }

    /// The clobber guard: a batch pass finishing after the NEXT meeting has
    /// started must leave that live snapshot completely alone.
    func test_attach_does_not_clobber_a_live_recording() throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        let id = UUID()
        writer.begin(title: nil, source: nil, liveAvailable: true)
        writer.finish(recordingID: id, transcriptIsFinal: false)

        writer.begin(title: "Next", source: nil, liveAvailable: true)
        let liveSession = try XCTUnwrap(snapshot()).sessionID

        writer.attachHandoff(forRecording: id)

        let snap = try XCTUnwrap(snapshot())
        XCTAssertEqual(snap.state, .recording)
        XCTAssertEqual(snap.sessionID, liveSession)
        XCTAssertNil(snap.finalRecordingID)
    }

    /// And once a new session has been and gone, the stale pending handoff is
    /// forgotten rather than stamped onto the newer session's snapshot.
    func test_attach_is_forgotten_across_sessions() throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        let first = UUID()
        writer.begin(title: nil, source: nil, liveAvailable: true)
        writer.finish(recordingID: first, transcriptIsFinal: false)

        writer.begin(title: "Next", source: nil, liveAvailable: true)
        let second = UUID()
        writer.finish(recordingID: second)

        writer.attachHandoff(forRecording: first)

        XCTAssertEqual(try XCTUnwrap(snapshot()).finalRecordingID, second,
                       "the newer session's own handoff must stand")
    }

    /// Attaching twice is harmless — the second call finds an id already there.
    func test_attach_is_idempotent() throws {
        let writer = LiveTranscriptSidecarWriter(root: root, minWriteInterval: 0)
        let id = UUID()
        writer.begin(title: nil, source: nil, liveAvailable: true)
        writer.finish(recordingID: id, transcriptIsFinal: false)
        writer.attachHandoff(forRecording: id)
        let revisionAfterFirst = try XCTUnwrap(snapshot()).revision

        writer.attachHandoff(forRecording: id)

        let snap = try XCTUnwrap(snapshot())
        XCTAssertEqual(snap.finalRecordingID, id)
        XCTAssertEqual(snap.revision, revisionAfterFirst, "no second write")
    }
}
