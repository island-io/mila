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
        XCTAssertNotNil(RecordingStore.audioTrimProblem(result.audio))
        XCTAssertNotNil(store.trimNotice,
                        "the user is told the audio was kept, through the store so it survives navigation")
    }

    func test_end_conversation_with_unusable_timings_still_trims_the_transcript() async throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        // Zero-length timings (as a hand-edited or degenerate store can hold)
        // give no cut point.
        let segs = [TranscriptSegment(start: 0, end: 0, text: "kept"),
                    TranscriptSegment(start: 0, end: 0, text: "dropped")]
        let rec = recording(segments: segs)
        store.add(rec)

        let outcome = await store.endConversation(afterSegment: segs[0].id, recordingID: rec.id)
        let result = try XCTUnwrap(outcome, "the transcript edit must not depend on the audio cut")

        XCTAssertEqual(result.recording.segments.map(\.text), ["kept"])
        XCTAssertEqual(result.audio, .noCutPoint)
        XCTAssertNotNil(store.trimNotice)
    }

    func test_end_conversation_reports_audio_that_ends_before_the_cut() async throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        let segs = fourLines()
        let rec = recording(segments: segs)
        // Two seconds of audio under eight seconds of lines.
        try TestSupport.writeSineWav(at: store.recordingsDirectory.appendingPathComponent(rec.audioFileName),
                                     durationSeconds: 2)
        store.add(rec)

        let outcome = await store.endConversation(afterSegment: segs[1].id, recordingID: rec.id)
        let result = try XCTUnwrap(outcome)

        XCTAssertEqual(result.audio, .audioEndsBeforeCut,
                       "the user was promised a cut; nothing happening must not read as success")
        XCTAssertNotNil(store.trimNotice)
        XCTAssertNil(store.audioRevisions[rec.id], "the file was not replaced, so players need not reload")
        assertNoTrimLeftovers(in: store.recordingsDirectory)
    }

    func test_successful_trim_bumps_the_audio_revision_only() async throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        let segs = fourLines()
        let rec = recording(segments: segs)
        try TestSupport.writeSineWav(at: store.recordingsDirectory.appendingPathComponent(rec.audioFileName),
                                     durationSeconds: 8)
        store.add(rec)

        _ = await store.endConversation(afterSegment: segs[2].id, recordingID: rec.id)

        XCTAssertEqual(store.audioRevisions[rec.id], 1)
        XCTAssertNil(store.trimNotice)
    }

    // MARK: - Post-stop speaker finalization

    /// After a live recording stops, `finalizeTail` re-diarizes a stop-time
    /// copy of the segments while the row already reads `.completed`, then
    /// writes that copy back — so an edit in that window would be undone.
    func test_edits_are_refused_while_speaker_finalization_is_pending() async throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        let segs = fourLines()
        let rec = recording(segments: segs)
        store.add(rec)
        var pending: Set<UUID> = [rec.id]
        store.isTranscriptEditBlocked = { pending.contains($0) }

        XCTAssertFalse(store.canEditTranscriptNow(rec))
        XCTAssertNil(store.deleteSegments([segs[0].id], recordingID: rec.id))
        let ended = await store.endConversation(afterSegment: segs[0].id, recordingID: rec.id)
        XCTAssertNil(ended)
        XCTAssertEqual(store.recordings.first?.segments.count, 4)

        pending.removeAll()
        XCTAssertTrue(store.canEditTranscriptNow(rec))
        XCTAssertNotNil(store.deleteSegments([segs[0].id], recordingID: rec.id))
    }

    // MARK: - Re-transcription during the audio cut

    /// A re-run started between the transcript edit and the audio cut would
    /// make the trim give up and transcribe the FULL audio, writing the
    /// removed lines back.
    func test_retranscription_is_refused_while_the_audio_cut_is_in_flight() async throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        let segs = fourLines()
        let rec = recording(segments: segs)
        try TestSupport.writeSineWav(at: store.recordingsDirectory.appendingPathComponent(rec.audioFileName),
                                     durationSeconds: 8)
        store.add(rec)

        let trim = Task { await store.endConversation(afterSegment: segs[1].id, recordingID: rec.id) }
        // The task runs on the main actor up to the off-main audio write, so
        // it is observable mid-flight after a yield.
        var spins = 0
        while !store.audioTrimPendingIDs.contains(rec.id), spins < 1000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(store.audioTrimPendingIDs.contains(rec.id), "never observed the trim in flight")
        XCTAssertNil(store.prepareForRetranscription(id: rec.id))
        XCTAssertEqual(store.recordings.first?.status, .completed, "the refused re-run must not touch the row")

        let result = await trim.value
        guard case .trimmed = result?.audio else {
            return XCTFail("the trim must not give up: \(String(describing: result?.audio))")
        }
        XCTAssertFalse(store.audioTrimPendingIDs.contains(rec.id))
        XCTAssertNotNil(store.prepareForRetranscription(id: rec.id), "allowed again once the cut is done")
    }

    // MARK: - Unsaved edits

    /// The `.txt` sidecar is what mila-mcp serves first, so a stale one must
    /// be reported and retried on a later write. The edit itself is in
    /// recordings.json, so it still stands — End Conversation Here must
    /// still go on to cut the audio, or it never could (the clicked line is
    /// now the last one, where the action is disabled).
    func test_an_edit_whose_sidecar_cannot_be_written_stands_is_reported_and_retried() throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        let segs = fourLines()
        let rec = recording(segments: segs)
        store.add(rec)
        let sidecar = store.transcriptURL(for: rec)
        let directory = store.recordingsDirectory.path
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory) }

        XCTAssertNotNil(store.deleteSegments([segs[2].id], recordingID: rec.id),
                        "recordings.json holds the edit, so it stands")
        XCTAssertNotNil(store.trimNotice, "a stale sidecar is still reported")

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
        store.rename(rec, to: "Call, renamed")  // any later write

        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "one two four",
                       "the stale sidecar still served the removed line")
    }

    /// When recordings.json itself does not take the edit, it is a real
    /// failure: not returned as done (so no audio cut follows) and reported.
    func test_an_edit_that_recordings_json_did_not_take_is_not_a_success() throws {
        let store = RecordingStore(rootDirectory: tempRoot)
        let segs = fourLines()
        let rec = recording(segments: segs)
        store.add(rec)
        // recordings.json lives at the root; the sidecars in `Recordings/`.
        let root = tempRoot.path
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root) }

        XCTAssertNil(store.deleteSegments([segs[2].id], recordingID: rec.id))
        XCTAssertNotNil(store.trimNotice)
    }

    // MARK: - Crash leftovers

    func test_trim_leftovers_are_swept_at_load() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        let leftover = first.recordingsDirectory
            .appendingPathComponent("\(RecordingStore.audioTrimTempPrefix)\(UUID().uuidString).wav")
        try TestSupport.writeSineWav(at: leftover, durationSeconds: 1)

        let relaunched = RecordingStore(rootDirectory: tempRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(relaunched.recordings.isEmpty)
    }

    // MARK: - Retained live snapshot lines

    func test_completed_live_snapshot_drops_its_lines_after_an_edit() throws {
        let writer = LiveTranscriptSidecarWriter(root: tempRoot, minWriteInterval: 0)
        let recordingID = UUID()
        writer.begin(title: nil, source: "meeting", liveAvailable: true)
        writer.update(segments: fourLines(), speakerNames: ["SPEAKER_00": "Dana"])
        writer.finish(recordingID: recordingID)
        let before = try XCTUnwrap(LiveTranscriptSnapshot.read(root: tempRoot))

        writer.dropRetainedLines(afterEditOf: recordingID)

        let after = try XCTUnwrap(LiveTranscriptSnapshot.read(root: tempRoot))
        XCTAssertTrue(after.segments.isEmpty, "the deleted text must not stay on disk")
        XCTAssertTrue(after.speakerNames.isEmpty)
        XCTAssertEqual(after.state, .completed)
        XCTAssertEqual(after.finalRecordingID, recordingID, "the handoff is untouched")
        XCTAssertEqual(after.revision, before.revision, "nothing a poller reads changed")
    }

    func test_completed_live_snapshot_of_another_recording_is_left_alone() throws {
        let writer = LiveTranscriptSidecarWriter(root: tempRoot, minWriteInterval: 0)
        writer.begin(title: nil, source: "meeting", liveAvailable: true)
        writer.update(segments: fourLines(), speakerNames: [:])
        writer.finish(recordingID: UUID())

        writer.dropRetainedLines(afterEditOf: UUID())

        XCTAssertEqual(try XCTUnwrap(LiveTranscriptSnapshot.read(root: tempRoot)).segments.count, 4)
    }

    func test_interrupted_live_snapshot_drops_its_lines_after_any_edit() throws {
        // What a crash mid-meeting leaves: a `recording` snapshot nobody
        // closed. Written directly — a live writer would keep heartbeating.
        let lines = fourLines().map {
            LiveTranscriptSnapshot.Segment(start: $0.start, end: $0.end, text: $0.text, speaker: $0.speaker)
        }
        try LiveTranscriptSnapshot(recordingStartedAt: Date(), updatedAt: Date(), segments: lines)
            .write(root: tempRoot)
        // Next launch: the leftover `recording` snapshot becomes `interrupted`.
        let relaunched = LiveTranscriptSidecarWriter(root: tempRoot, minWriteInterval: 0)
        relaunched.cleanupAtLaunch()
        XCTAssertEqual(try XCTUnwrap(LiveTranscriptSnapshot.read(root: tempRoot)).state, .interrupted)

        relaunched.dropRetainedLines(afterEditOf: UUID())

        let after = try XCTUnwrap(LiveTranscriptSnapshot.read(root: tempRoot))
        XCTAssertEqual(after.state, .interrupted)
        XCTAssertTrue(after.segments.isEmpty)
    }

    func test_live_snapshot_of_a_recording_in_progress_is_left_alone() throws {
        let writer = LiveTranscriptSidecarWriter(root: tempRoot, minWriteInterval: 0)
        writer.begin(title: nil, source: "meeting", liveAvailable: true)
        writer.update(segments: fourLines(), speakerNames: [:])

        writer.dropRetainedLines(afterEditOf: UUID())

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
