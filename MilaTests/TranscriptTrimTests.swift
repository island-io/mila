import XCTest
import AVFoundation
import MilaKit
import TranscriptionCore
@testable import Mila

/// "Delete Segment(s)" and "End Conversation Here" (island-io/mila#357).
///
/// Deleting lines is a privacy action (`bugbot-rules/deleted-data-stays-
/// deleted.md`), so beyond the pure edit rules this suite checks every place
/// the transcript is copied to: the row, `recordings.json`, the `.txt` and
/// `.srt` sidecars, what mila-mcp's `MilaStoreReader` serves, and the
/// completed live snapshot. And for "End Conversation Here", that the audio
/// file really is shorter and the row's duration says so.
@MainActor
final class TranscriptTrimTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "TranscriptTrimTests")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        super.tearDown()
    }

    // MARK: - Fixtures

    /// Four two-second lines, back to back: 0–2, 2–4, 4–6, 6–8.
    private func fourLines() -> [TranscriptSegment] {
        ["one", "two", "three", "four"].enumerated().map { i, text in
            TranscriptSegment(start: Double(i) * 2, end: Double(i) * 2 + 2,
                              text: " \(text)", speaker: i.isMultiple(of: 2) ? "SPEAKER_00" : "SPEAKER_01")
        }
    }

    private func recording(segments: [TranscriptSegment],
                           audioFileName: String = "call.wav",
                           status: TranscriptionStatus = .completed,
                           actionItems: [ActionItem]? = nil) -> Recording {
        Recording(title: "Call",
                  duration: segments.last?.end ?? 0,
                  source: .meeting,
                  audioFileName: audioFileName,
                  status: status,
                  language: "en",
                  segments: segments,
                  fullText: TranscriptFormatter.joinedFullText(segments: segments),
                  actionItems: actionItems)
    }

    private func item(_ text: String, at seconds: Double) -> ActionItem {
        ActionItem(id: UUID().uuidString, text: text, speaker: nil,
                   timestampSeconds: seconds, source: .llmInferred, addedAt: Date())
    }

    // MARK: - Recording.removingSegments

    func test_removing_a_range_keeps_the_rest_in_order_and_rebuilds_the_text() throws {
        let segs = fourLines()
        let rec = recording(segments: segs)

        let edited = try XCTUnwrap(rec.removingSegments([segs[1].id, segs[2].id]))

        XCTAssertEqual(edited.segments.map(\.id), [segs[0].id, segs[3].id])
        XCTAssertEqual(edited.fullText, "one four")
        XCTAssertEqual(edited.duration, rec.duration, "a mid-transcript delete keeps the audio, so the duration")
        XCTAssertEqual(edited.id, rec.id)
    }

    func test_removing_nothing_or_everything_is_refused() {
        let segs = fourLines()
        let rec = recording(segments: segs)

        XCTAssertNil(rec.removingSegments([]))
        XCTAssertNil(rec.removingSegments([UUID()]), "an id that names no line changes nothing")
        XCTAssertNil(rec.removingSegments(Set(segs.map(\.id))),
                     "emptying the transcript is deleting the recording, not trimming it")
    }

    // MARK: - Recording.endingConversation

    func test_ending_the_conversation_drops_every_later_line() throws {
        let segs = fourLines()
        let rec = recording(segments: segs)

        let edited = try XCTUnwrap(rec.endingConversation(at: segs[1].id))

        XCTAssertEqual(edited.segments.map(\.id), [segs[0].id, segs[1].id])
        XCTAssertEqual(edited.fullText, "one two")
        XCTAssertEqual(edited.duration, rec.duration,
                       "only a real audio trim may shorten the duration")
    }

    func test_ending_at_the_last_line_or_an_unknown_line_is_refused() {
        let segs = fourLines()
        let rec = recording(segments: segs)

        XCTAssertNil(rec.endingConversation(at: segs[3].id))
        XCTAssertNil(rec.endingConversation(at: UUID()))
        XCTAssertEqual(TranscriptTrim.linesAfter(segs[3].id, in: segs), 0)
        XCTAssertEqual(TranscriptTrim.linesAfter(segs[0].id, in: segs), 3)
    }

    func test_ending_the_conversation_drops_action_items_from_after_the_cut() throws {
        let segs = fourLines()
        let early = item("send the deck", at: 1)
        let undated = item("no timestamp", at: 0)
        let late = item("book dinner", at: 7)
        let rec = recording(segments: segs, actionItems: [early, undated, late])

        let edited = try XCTUnwrap(rec.endingConversation(at: segs[1].id))

        XCTAssertEqual(edited.actionItems?.map(\.text), ["send the deck", "no timestamp"])
    }

    func test_ending_the_conversation_keeps_nil_action_items_nil() throws {
        let segs = fourLines()
        let edited = try XCTUnwrap(recording(segments: segs).endingConversation(at: segs[0].id))
        XCTAssertNil(edited.actionItems, "nil means Live AI never ran; trimming must not change that")
    }

    // MARK: - TranscriptTrim.audioCutTime

    func test_cut_never_reaches_into_the_first_removed_line() {
        // Back to back: no room for padding.
        let segs = fourLines()
        XCTAssertEqual(TranscriptTrim.audioCutTime(endingAt: segs[1].id, in: segs), 4)

        // A pause after the kept line: padded by the tail allowance.
        let gap = [TranscriptSegment(start: 0, end: 2, text: "a"),
                   TranscriptSegment(start: 5, end: 6, text: "b")]
        XCTAssertEqual(TranscriptTrim.audioCutTime(endingAt: gap[0].id, in: gap),
                       2 + TranscriptTrim.audioTailPadding)

        // A short pause: padded only up to the next line's start.
        let short = [TranscriptSegment(start: 0, end: 2, text: "a"),
                     TranscriptSegment(start: 2.2, end: 3, text: "b")]
        XCTAssertEqual(try XCTUnwrap(TranscriptTrim.audioCutTime(endingAt: short[0].id, in: short)),
                       2.2, accuracy: 1e-9)

        // An earlier kept line that runs past the clicked one's end.
        let overlap = [TranscriptSegment(start: 0, end: 5, text: "a"),
                       TranscriptSegment(start: 1, end: 3, text: "b"),
                       TranscriptSegment(start: 6, end: 7, text: "c")]
        XCTAssertEqual(TranscriptTrim.audioCutTime(endingAt: overlap[1].id, in: overlap),
                       5 + TranscriptTrim.audioTailPadding)

        XCTAssertNil(TranscriptTrim.audioCutTime(endingAt: segs[3].id, in: segs),
                     "nothing after the last line, so nothing to cut")
    }

    // MARK: - TranscriptSelection

    func test_plain_click_selects_one_line_and_shift_click_extends_a_range() {
        let ids = fourLines().map(\.id)
        var selection = TranscriptSelection()

        selection = selection.clicking(ids[1], kind: .plain, order: ids)
        XCTAssertEqual(selection.ids, [ids[1]])

        selection = selection.clicking(ids[3], kind: .extend, order: ids)
        XCTAssertEqual(selection.ids, [ids[1], ids[2], ids[3]])

        // Re-spans from the same anchor, in either direction.
        selection = selection.clicking(ids[0], kind: .extend, order: ids)
        XCTAssertEqual(selection.ids, [ids[0], ids[1]])

        selection = selection.clicking(ids[2], kind: .plain, order: ids)
        XCTAssertEqual(selection.ids, [ids[2]])
    }

    func test_shift_click_with_nothing_selected_acts_as_a_plain_click() {
        let ids = fourLines().map(\.id)
        let selection = TranscriptSelection().clicking(ids[2], kind: .extend, order: ids)
        XCTAssertEqual(selection.ids, [ids[2]])
        XCTAssertEqual(selection.anchor, ids[2])
    }

    func test_command_click_toggles_one_line() {
        let ids = fourLines().map(\.id)
        var selection = TranscriptSelection().clicking(ids[0], kind: .plain, order: ids)
        selection = selection.clicking(ids[2], kind: .toggle, order: ids)
        XCTAssertEqual(selection.ids, [ids[0], ids[2]])
        selection = selection.clicking(ids[0], kind: .toggle, order: ids)
        XCTAssertEqual(selection.ids, [ids[2]])
    }

    func test_pruning_drops_lines_that_are_gone() {
        let ids = fourLines().map(\.id)
        var selection = TranscriptSelection().clicking(ids[0], kind: .plain, order: ids)
        selection = selection.clicking(ids[2], kind: .extend, order: ids)

        let pruned = selection.pruned(to: [ids[1], ids[3]])

        XCTAssertEqual(pruned.ids, [ids[1]])
        XCTAssertNil(pruned.anchor, "the anchor line was deleted")
    }

    func test_context_delete_targets_the_selection_only_when_the_clicked_line_is_in_it() {
        let ids = fourLines().map(\.id)
        var selection = TranscriptSelection().clicking(ids[0], kind: .plain, order: ids)
        selection = selection.clicking(ids[1], kind: .extend, order: ids)

        XCTAssertEqual(selection.deletionTarget(forContextClickOn: ids[1]), [ids[0], ids[1]])
        XCTAssertEqual(selection.deletionTarget(forContextClickOn: ids[3]), [ids[3]])
    }

    // MARK: - RecordingStore.deleteSegments

    func test_delete_rewrites_every_copy_of_the_transcript() throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        let segs = fourLines()
        let rec = recording(segments: segs)
        store.add(rec)
        var hookSaw: Recording?
        store.onTranscriptLinesRemoved = { hookSaw = $0 }

        let updated = try XCTUnwrap(store.deleteSegments([segs[2].id], recordingID: rec.id))

        XCTAssertEqual(updated.segments.map(\.text), [" one", " two", " four"])
        XCTAssertEqual(store.recordings.first?.segments.count, 3)
        XCTAssertEqual(hookSaw?.segments.map(\.id), updated.segments.map(\.id),
                       "copies outside the store (the live snapshot) are told what remains")

        // The `.txt` sidecar the MCP helper reads first.
        let txt = try String(contentsOf: store.transcriptURL(for: updated), encoding: .utf8)
        XCTAssertEqual(txt, "one two four")

        // The `.srt` sidecar.
        let srt = try String(contentsOf: store.subtitleURL(for: updated), encoding: .utf8)
        XCTAssertFalse(srt.contains("three"), "the deleted line survived in the .srt")
        XCTAssertTrue(srt.contains("four"))

        // recordings.json, as a fresh app launch and mila-mcp read it.
        let relaunched = RecordingStore(rootDirectory: tempRoot)
        XCTAssertEqual(relaunched.recordings.first?.segments.map(\.text), [" one", " two", " four"])
        let reader = MilaStoreReader(recordingsDirectory: store.recordingsDirectory,
                                     storeFileURL: store.storeURL)
        let stored = try XCTUnwrap(reader.recording(id: rec.id))
        XCTAssertEqual(stored.segments.count, 3)
        XCTAssertFalse(reader.transcriptText(for: stored).contains("three"))
        XCTAssertFalse(reader.namedTranscript(for: stored).contains("three"))
    }

    func test_delete_is_refused_while_a_transcription_pass_is_in_flight() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let segs = fourLines()
        let rec = recording(segments: segs, status: .running)
        store.add(rec)

        XCTAssertNil(store.deleteSegments([segs[0].id], recordingID: rec.id),
                     "the pass would write its own segments back over the edit")
        XCTAssertEqual(store.recordings.first?.segments.count, 4)
    }

    // MARK: - RecordingStore.endConversation

    func test_end_conversation_trims_the_transcript_and_the_wav() async throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        let segs = fourLines()
        let rec = recording(segments: segs)
        try TestSupport.writeSineWav(at: store.recordingsDirectory.appendingPathComponent(rec.audioFileName),
                                     durationSeconds: 8)
        store.add(rec)

        let outcome = await store.endConversation(afterSegment: segs[1].id, recordingID: rec.id)
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.recording.segments.map(\.id), [segs[0].id, segs[1].id])
        guard case .trimmed(let duration) = result.audio else {
            return XCTFail("expected the audio to be trimmed, got \(result.audio)")
        }
        XCTAssertEqual(duration, 4, accuracy: 0.01)
        XCTAssertEqual(store.recordings.first?.duration ?? 0, 4, accuracy: 0.01)

        let file = try AVAudioFile(forReading: store.audioURL(for: result.recording))
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 4, accuracy: 0.01)
        XCTAssertEqual(try String(contentsOf: store.transcriptURL(for: result.recording), encoding: .utf8),
                       "one two")
        assertNoTrimLeftovers(in: store.recordingsDirectory)

        // Persisted, so the next launch (and mila-mcp) agree.
        let relaunched = RecordingStore(rootDirectory: tempRoot)
        XCTAssertEqual(relaunched.recordings.first?.duration ?? 0, 4, accuracy: 0.01)
        XCTAssertEqual(relaunched.recordings.count, 1, "no leftover was recovered as an orphan recording")
    }

    func test_end_conversation_trims_a_compressed_m4a() async throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        let segs = fourLines()
        let wav = store.recordingsDirectory.appendingPathComponent("source.wav")
        try TestSupport.writeSineWav(at: wav, durationSeconds: 8)
        let m4a = store.recordingsDirectory.appendingPathComponent("call.m4a")
        try await AudioCompressor.compress(wavURL: wav, toM4A: m4a)
        try FileManager.default.removeItem(at: wav)
        let rec = recording(segments: segs, audioFileName: "call.m4a")
        store.add(rec)

        let outcome = await store.endConversation(afterSegment: segs[1].id, recordingID: rec.id)
        let result = try XCTUnwrap(outcome)

        guard case .trimmed(let duration) = result.audio else {
            return XCTFail("expected the audio to be trimmed, got \(result.audio)")
        }
        XCTAssertEqual(duration, 4, accuracy: 0.05)
        let file = try AVAudioFile(forReading: store.audioURL(for: result.recording))
        // AAC framing rounds the length; it must still be clearly the 4 s
        // prefix, not the 8 s original.
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 4, accuracy: 0.1)
        assertNoTrimLeftovers(in: store.recordingsDirectory)
    }

    func test_end_conversation_without_audio_still_trims_the_transcript() async throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        let segs = fourLines()
        let rec = recording(segments: segs)  // no audio file written
        store.add(rec)

        let outcome = await store.endConversation(afterSegment: segs[0].id, recordingID: rec.id)
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.audio, .unsupported)
        XCTAssertEqual(result.recording.segments.count, 1)
        XCTAssertEqual(result.recording.duration, rec.duration,
                       "the audio was not cut, so the duration must not claim it was")
        XCTAssertNotNil(RecordingDetailView.audioTrimProblem(result.audio),
                        "the user is told the audio was kept")
    }

    // MARK: - Completed live snapshot

    func test_completed_live_snapshot_loses_the_deleted_lines() throws {
        let writer = LiveTranscriptSidecarWriter(root: tempRoot, minWriteInterval: 0)
        let segs = fourLines()
        let recordingID = UUID()
        writer.begin(title: nil, source: "meeting", liveAvailable: true)
        writer.update(segments: segs, speakerNames: [:])
        writer.finish(recordingID: recordingID)
        let before = try XCTUnwrap(LiveTranscriptSnapshot.read(root: tempRoot))

        writer.replaceCompletedTranscript(forRecording: recordingID,
                                          segments: Array(segs.prefix(2)),
                                          speakerNames: [:])

        let after = try XCTUnwrap(LiveTranscriptSnapshot.read(root: tempRoot))
        XCTAssertEqual(after.segments.map(\.text), [" one", " two"])
        XCTAssertEqual(after.revision, before.revision + 1)
        XCTAssertEqual(after.segmentsRemovedAtRevision, after.revision,
                       "pollers holding the removed lines must be sent the full set")
        XCTAssertEqual(after.finalRecordingID, recordingID)
        XCTAssertEqual(after.state, .completed)
    }

    func test_live_snapshot_of_another_recording_is_left_alone() throws {
        let writer = LiveTranscriptSidecarWriter(root: tempRoot, minWriteInterval: 0)
        let segs = fourLines()
        writer.begin(title: nil, source: "meeting", liveAvailable: true)
        writer.update(segments: segs, speakerNames: [:])
        writer.finish(recordingID: UUID())
        let before = try XCTUnwrap(LiveTranscriptSnapshot.read(root: tempRoot))

        writer.replaceCompletedTranscript(forRecording: UUID(), segments: [], speakerNames: [:])

        let after = try XCTUnwrap(LiveTranscriptSnapshot.read(root: tempRoot))
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.segments.count, 4)
    }

    func test_live_snapshot_of_a_recording_in_progress_is_left_alone() throws {
        let writer = LiveTranscriptSidecarWriter(root: tempRoot, minWriteInterval: 0)
        let segs = fourLines()
        writer.begin(title: nil, source: "meeting", liveAvailable: true)
        writer.update(segments: segs, speakerNames: [:])

        writer.replaceCompletedTranscript(forRecording: UUID(), segments: [], speakerNames: [:])

        let after = try XCTUnwrap(LiveTranscriptSnapshot.read(root: tempRoot))
        XCTAssertEqual(after.state, .recording)
        XCTAssertEqual(after.segments.count, 4)
    }

    // MARK: - Helpers

    private func assertNoTrimLeftovers(in directory: URL,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertFalse(names.contains { $0.hasPrefix(".mila-trim-") },
                       "a temporary trim file was left behind: \(names)", file: file, line: line)
    }
}
