import XCTest
@testable import Mila

/// A `recordings.json` that can't be fully read must never be silently
/// replaced by an emptier file (improvement plan item 1).
@MainActor
final class RecordingStoreCorruptLoadTests: XCTestCase {

    private var tempRoot: URL!
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
}
