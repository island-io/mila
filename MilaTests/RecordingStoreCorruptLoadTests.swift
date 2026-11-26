import XCTest
@testable import Mila

/// A `recordings.json` that can't be fully read must never be silently
/// replaced by an emptier file (improvement plan item 1).
@MainActor
final class RecordingStoreCorruptLoadTests: XCTestCase {

    private var tempRoot: URL!
    /// Read or altered right after `add`, which hands its write to the
    /// background writer (#406): each test waits for it first. A relaunched
    /// store needs no wait, since `load()` does the same.
    private var storeFile: URL { tempRoot.appendingPathComponent("recordings.json") }

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaTests-corrupt-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        super.tearDown()
    }

    private func damagedBackups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("recordings.damaged-") }
    }

    func test_missing_file_is_a_clean_start_without_an_issue() {
        let store = RecordingStore(rootDirectory: tempRoot)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertNil(store.libraryLoadIssue)
    }

    func test_truncated_file_is_backed_up_before_the_next_write() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.add(Recording(title: "A", source: .microphone, audioFileName: "a.wav"))
        first.add(Recording(title: "B", source: .microphone, audioFileName: "b.wav"))
        first.waitForPendingWrites()
        let original = try Data(contentsOf: storeFile)
        try original.prefix(original.count / 2).write(to: storeFile)
        let truncated = try Data(contentsOf: storeFile)

        let relaunched = RecordingStore(rootDirectory: tempRoot)
        XCTAssertEqual(relaunched.libraryLoadIssue?.kind, .undecodable)
        // The next mutation overwrites recordings.json...
        relaunched.add(Recording(title: "C", source: .microphone, audioFileName: "c.wav"))

        // ...but the unreadable bytes survive in the backup.
        let backups = try damagedBackups()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: backups[0]), truncated)
        XCTAssertEqual(relaunched.libraryLoadIssue?.backup?.lastPathComponent,
                       backups[0].lastPathComponent)
    }

    func test_one_bad_row_does_not_drop_the_others() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.add(Recording(title: "Keep 1", source: .microphone, audioFileName: "a.wav"))
        first.add(Recording(title: "Keep 2", source: .microphone, audioFileName: "b.wav"))
        first.waitForPendingWrites()
        var rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeFile)) as? [[String: Any]])
        rows.append(["id": "not-a-uuid", "title": 42])
        try JSONSerialization.data(withJSONObject: rows).write(to: storeFile)

        let relaunched = RecordingStore(rootDirectory: tempRoot)

        XCTAssertEqual(Set(relaunched.recordings.map(\.title)), ["Keep 1", "Keep 2"])
        XCTAssertEqual(relaunched.libraryLoadIssue?.kind, .rowsDropped)
        XCTAssertEqual(relaunched.libraryLoadIssue?.droppedRows, 1)
        XCTAssertEqual(try damagedBackups().count, 1, "the original with the bad row is kept")
    }

    func test_orphan_audio_is_still_recovered_when_the_file_is_undecodable() throws {
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: storeFile)
        let wav = tempRoot.appendingPathComponent("Recordings/crashed.wav")
        try Data(count: RecordingStore.emptyWAVByteCount + 1).write(to: wav)

        let store = RecordingStore(rootDirectory: tempRoot)

        XCTAssertEqual(store.recordings.map(\.audioFileName), ["crashed.wav"])
        XCTAssertEqual(store.libraryLoadIssue?.kind, .undecodable)
    }

    /// A row that can't be decoded still has its audio on disk; that audio
    /// comes back as a "Recovered recording" queued for transcription, and
    /// the rewritten file loads cleanly on the next launch.
    func test_a_dropped_row_with_audio_comes_back_as_a_recovered_recording() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.add(Recording(title: "Keep", source: .microphone, audioFileName: "keep.wav"))
        first.waitForPendingWrites()
        var rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeFile)) as? [[String: Any]])
        rows.append(["id": "not-a-uuid", "title": 42, "audioFileName": "lost.wav"])
        try JSONSerialization.data(withJSONObject: rows).write(to: storeFile)
        try Data(count: RecordingStore.emptyWAVByteCount + 1)
            .write(to: tempRoot.appendingPathComponent("Recordings/lost.wav"))

        let relaunched = RecordingStore(rootDirectory: tempRoot)

        let lost = try XCTUnwrap(relaunched.recordings.first { $0.audioFileName == "lost.wav" })
        XCTAssertTrue(lost.title.hasPrefix("Recovered recording"))
        XCTAssertEqual(lost.status, .pending)
        XCTAssertEqual(relaunched.consumePendingRecoveryIDs(), [lost.id])
        XCTAssertEqual(relaunched.libraryLoadIssue?.kind, .rowsDropped)
        XCTAssertEqual(relaunched.libraryLoadIssue?.droppedRows, 1)
        XCTAssertEqual(relaunched.libraryLoadIssue?.recoveredRecordings, 1)

        let again = RecordingStore(rootDirectory: tempRoot)
        XCTAssertNil(again.libraryLoadIssue)
        XCTAssertEqual(Set(again.recordings.map(\.audioFileName)), ["keep.wav", "lost.wav"])
        XCTAssertEqual(try damagedBackups().count, 1)
    }

    /// The `.txt` sidecar is the only copy of a transcript (and of edits to
    /// it). A dropped row's recovery must load it, not re-transcribe over it.
    func test_a_dropped_row_keeps_its_saved_transcript_and_is_not_retranscribed() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.add(Recording(title: "Keep", source: .microphone, audioFileName: "keep.wav"))
        first.waitForPendingWrites()
        var rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeFile)) as? [[String: Any]])
        rows.append(["id": "not-a-uuid", "title": 42, "audioFileName": "lost.wav"])
        try JSONSerialization.data(withJSONObject: rows).write(to: storeFile)
        let recordings = tempRoot.appendingPathComponent("Recordings")
        try Data(count: RecordingStore.emptyWAVByteCount + 1)
            .write(to: recordings.appendingPathComponent("lost.wav"))
        let sidecar = recordings.appendingPathComponent("lost.txt")
        try "Edited transcript".write(to: sidecar, atomically: true, encoding: .utf8)

        let relaunched = RecordingStore(rootDirectory: tempRoot)

        let lost = try XCTUnwrap(relaunched.recordings.first { $0.audioFileName == "lost.wav" })
        XCTAssertTrue(lost.title.hasPrefix("Recovered recording"))
        XCTAssertEqual(lost.status, .completed)
        XCTAssertEqual(lost.fullText, "Edited transcript")
        XCTAssertTrue(relaunched.consumePendingRecoveryIDs().isEmpty)
        XCTAssertEqual(relaunched.libraryLoadIssue?.recoveredRecordings, 1)
        XCTAssertEqual(relaunched.libraryLoadIssue?.recoveredForTranscription, 0)
        XCTAssertEqual(try String(contentsOf: sidecar, encoding: .utf8), "Edited transcript")
    }

    /// Trash keeps its audio on disk until purged. A dropped row that was in
    /// Recently Deleted must go back there, not reappear in the library.
    func test_a_dropped_trashed_row_goes_back_to_recently_deleted() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.add(Recording(title: "Keep", source: .microphone, audioFileName: "keep.wav"))
        first.waitForPendingWrites()
        var rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeFile)) as? [[String: Any]])
        rows.append(["id": "not-a-uuid", "title": 42, "audioFileName": "trashed.wav",
                     "deletedAt": "2026-11-01T10:00:00Z"])
        try JSONSerialization.data(withJSONObject: rows).write(to: storeFile)
        try Data(count: RecordingStore.emptyWAVByteCount + 1)
            .write(to: tempRoot.appendingPathComponent("Recordings/trashed.wav"))

        let relaunched = RecordingStore(rootDirectory: tempRoot)

        let trashed = try XCTUnwrap(relaunched.recordings.first { $0.audioFileName == "trashed.wav" })
        XCTAssertEqual(trashed.deletedAt, ISO8601DateFormatter().date(from: "2026-11-01T10:00:00Z"))
        XCTAssertNotEqual(trashed.status, .pending)
        XCTAssertTrue(relaunched.consumePendingRecoveryIDs().isEmpty)
        XCTAssertEqual(relaunched.libraryLoadIssue?.recoveredToTrash, 1)
        XCTAssertEqual(relaunched.libraryLoadIssue?.recoveredForTranscription, 0)

        let again = RecordingStore(rootDirectory: tempRoot)
        XCTAssertNotNil(again.recordings.first { $0.audioFileName == "trashed.wav" }?.deletedAt)
    }

    /// With no audio to recover nothing else writes the store, so `load()`
    /// itself must rewrite it — otherwise every launch copies the same
    /// damaged file to yet another backup.
    func test_a_damaged_file_is_backed_up_once_not_on_every_launch() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.add(Recording(title: "Keep", source: .microphone, audioFileName: "keep.wav"))
        first.waitForPendingWrites()
        var rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeFile)) as? [[String: Any]])
        rows.append(["id": "not-a-uuid", "title": 42, "audioFileName": "gone.wav"])
        try JSONSerialization.data(withJSONObject: rows).write(to: storeFile)

        let relaunched = RecordingStore(rootDirectory: tempRoot)
        XCTAssertEqual(relaunched.libraryLoadIssue?.recoveredRecordings, 0)
        _ = RecordingStore(rootDirectory: tempRoot)
        let third = RecordingStore(rootDirectory: tempRoot)

        XCTAssertNil(third.libraryLoadIssue)
        XCTAssertEqual(third.recordings.map(\.title), ["Keep"])
        XCTAssertEqual(try damagedBackups().count, 1)
    }

    /// Closing the banner hides it; it must not lift the write guard, or the
    /// next mutation replaces the unreadable file with this session's list.
    func test_dismissing_the_unreadable_banner_keeps_the_file_untouched() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.add(Recording(title: "A", source: .microphone, audioFileName: "a.wav"))
        first.waitForPendingWrites()
        let original = try Data(contentsOf: storeFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: storeFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storeFile.path) }

        let relaunched = RecordingStore(rootDirectory: tempRoot)
        XCTAssertEqual(relaunched.libraryLoadIssue?.kind, .unreadable)
        relaunched.dismissLibraryLoadIssue()
        XCTAssertNil(relaunched.libraryLoadIssue)
        relaunched.add(Recording(title: "B", source: .microphone, audioFileName: "b.wav"))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storeFile.path)
        XCTAssertEqual(try Data(contentsOf: storeFile), original)
    }

    func test_a_healthy_store_reports_no_issue_and_no_backup() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.add(Recording(title: "A", source: .microphone, audioFileName: "a.wav"))
        let relaunched = RecordingStore(rootDirectory: tempRoot)
        XCTAssertNil(relaunched.libraryLoadIssue)
        XCTAssertTrue(try damagedBackups().isEmpty)
    }

    /// Appends `row` to recordings.json as written by a healthy store holding
    /// one "Keep" recording. `row` carries an invalid `id`, so it no longer
    /// decodes as a `Recording`.
    private func writeStoreWithDroppedRow(_ row: [String: Any]) throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.add(Recording(title: "Keep", source: .microphone, audioFileName: "keep.wav"))
        first.waitForPendingWrites()
        var rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: storeFile)) as? [[String: Any]])
        rows.append(row.merging(["id": "not-a-uuid", "title": 42]) { _, bad in bad })
        try JSONSerialization.data(withJSONObject: rows).write(to: storeFile)
    }

    private var recordingsDir: URL { tempRoot.appendingPathComponent("Recordings") }

    /// Compressed and imported audio is `.m4a`. A dropped row that names one
    /// comes back too, with its summary (or the next `update` deletes the
    /// summary sidecar for being empty) and its Voice Memos identity (or the
    /// next sync imports the memo a second time).
    func test_a_dropped_m4a_row_comes_back_with_its_summary_and_memo_identity() throws {
        try writeStoreWithDroppedRow(["audioFileName": "memo.m4a", "source": "voiceMemo",
                                      "voiceMemoUniqueID": "memo-1", "voiceMemoFolderUUID": "folder-1"])
        try Data(count: 1024).write(to: recordingsDir.appendingPathComponent("memo.m4a"))
        try "Transcript".write(to: recordingsDir.appendingPathComponent("memo.txt"),
                               atomically: true, encoding: .utf8)
        let summaryFile = recordingsDir.appendingPathComponent("memo.summary.txt")
        try "Summary".write(to: summaryFile, atomically: true, encoding: .utf8)

        let relaunched = RecordingStore(rootDirectory: tempRoot)

        var memo = try XCTUnwrap(relaunched.recordings.first { $0.audioFileName == "memo.m4a" })
        XCTAssertEqual(memo.status, .completed)
        XCTAssertEqual(memo.fullText, "Transcript")
        XCTAssertEqual(memo.summary, "Summary")
        XCTAssertEqual(memo.source, .voiceMemo)
        XCTAssertEqual(memo.voiceMemoUniqueID, "memo-1")
        XCTAssertEqual(memo.voiceMemoFolderUUID, "folder-1")
        XCTAssertEqual(relaunched.libraryLoadIssue?.recoveredRecordings, 1)

        memo.title = "Renamed"
        relaunched.update(memo)
        XCTAssertEqual(try String(contentsOf: summaryFile, encoding: .utf8), "Summary")
    }

    /// An unreferenced `.m4a` that no dropped row names is a compression that
    /// stopped before its save; a `.wav` sharing a live row's base name is
    /// the source a finished compression didn't get to delete. Neither is a
    /// recording of its own, and the second would share the live row's
    /// sidecars.
    func test_compression_leftovers_are_not_recovered_as_recordings() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.add(Recording(title: "Compressed", source: .microphone, audioFileName: "done.m4a"))
        try Data(count: RecordingStore.emptyWAVByteCount + 1)
            .write(to: recordingsDir.appendingPathComponent("done.wav"))
        try Data(count: 1024).write(to: recordingsDir.appendingPathComponent("stray.m4a"))

        let relaunched = RecordingStore(rootDirectory: tempRoot)

        XCTAssertEqual(relaunched.recordings.map(\.audioFileName), ["done.m4a"])
        XCTAssertTrue(relaunched.consumePendingRecoveryIDs().isEmpty)
    }

    /// The same leftover beside a DROPPED compressed row: the `.m4a` comes
    /// back as that row, and the `.wav` is not added as a second recording
    /// sharing its sidecars — nor, when the row was in Recently Deleted, as
    /// a live one.
    func test_a_dropped_m4a_rows_leftover_wav_is_not_recovered_too() throws {
        try writeStoreWithDroppedRow(["audioFileName": "lost.m4a",
                                      "deletedAt": "2026-01-02T03:04:05Z"])
        try Data(count: 1024).write(to: recordingsDir.appendingPathComponent("lost.m4a"))
        try Data(count: RecordingStore.emptyWAVByteCount + 1)
            .write(to: recordingsDir.appendingPathComponent("lost.wav"))

        let relaunched = RecordingStore(rootDirectory: tempRoot)

        XCTAssertEqual(relaunched.recordings.map(\.audioFileName).sorted(), ["keep.wav", "lost.m4a"])
        XCTAssertNotNil(relaunched.recordings.first { $0.audioFileName == "lost.m4a" }?.deletedAt)
        XCTAssertTrue(relaunched.consumePendingRecoveryIDs().isEmpty)
    }

    /// No transcription pass runs for a row settled from its saved
    /// transcript, so its length has to come from the audio file.
    func test_a_recovered_row_that_is_not_retranscribed_gets_its_duration() throws {
        try writeStoreWithDroppedRow(["audioFileName": "lost.wav"])
        try TestSupport.writeSineWav(at: recordingsDir.appendingPathComponent("lost.wav"),
                                     durationSeconds: 2)
        try "Text".write(to: recordingsDir.appendingPathComponent("lost.txt"),
                         atomically: true, encoding: .utf8)

        let relaunched = RecordingStore(rootDirectory: tempRoot)

        let lost = try XCTUnwrap(relaunched.recordings.first { $0.audioFileName == "lost.wav" })
        XCTAssertEqual(lost.status, .completed)
        XCTAssertEqual(lost.duration, 2, accuracy: 0.01)
    }

    /// While writes are off, compressing a recording made this session must
    /// keep its WAV: recordings.json can't name the `.m4a`, and the next
    /// launch's orphan sweep finds only `.wav` files.
    func test_compression_keeps_the_wav_while_writes_are_off() async throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        first.add(Recording(title: "A", source: .microphone, audioFileName: "a.wav"))
        first.waitForPendingWrites()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: storeFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storeFile.path) }
        let relaunched = RecordingStore(rootDirectory: tempRoot)
        XCTAssertEqual(relaunched.libraryLoadIssue?.kind, .unreadable)

        let wav = recordingsDir.appendingPathComponent("new.wav")
        try TestSupport.writeSineWav(at: wav)
        let rec = Recording(title: "New", source: .microphone, audioFileName: "new.wav", status: .completed)
        relaunched.add(rec)
        await relaunched.compressRecordingAudio(id: rec.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: recordingsDir.appendingPathComponent("new.m4a").path))
        XCTAssertEqual(relaunched.recordings.first { $0.id == rec.id }?.audioFileName, "new.wav")
    }
}
