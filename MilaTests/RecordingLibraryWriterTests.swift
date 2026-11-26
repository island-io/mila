import XCTest
@testable import Mila

/// Records every snapshot a writer encodes. It holds the encode of a
/// snapshot whose first title is `"hold"` until `release()`, so a test can
/// line writes up behind one that is still running, and fails the encode of
/// one whose first title is `"fail"`. Every wait is bounded.
///
/// With `holdingBackgroundEncodes`, it instead holds every encode that runs
/// off the main thread (the writer's queue) until `openBackground()`, so a
/// store test can see what is on disk with no background write behind it.
/// That hold is bounded too; `backgroundHoldTimedOut` says whether it ran
/// out, which would make the test's "held" premise false.
private final class EncodeProbe: @unchecked Sendable {
    struct Refused: Error {}

    private let lock = NSLock()
    private var log: [[String]] = []
    private let gate = DispatchSemaphore(value: 0)
    private let started = DispatchSemaphore(value: 0)
    private let holdsBackground: Bool
    private var backgroundOpen = false
    private var timedOut = false
    private let backgroundGate = DispatchSemaphore(value: 0)

    init(holdingBackgroundEncodes: Bool = false) {
        holdsBackground = holdingBackgroundEncodes
    }

    var encoded: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func encode(_ recordings: [Recording]) throws -> Data {
        let titles = recordings.map(\.title)
        lock.lock()
        log.append(titles)
        lock.unlock()
        if holdsBackground {
            if !Thread.isMainThread {
                lock.lock()
                let open = backgroundOpen
                lock.unlock()
                if !open {
                    started.signal()
                    if backgroundGate.wait(timeout: .now() + 10) == .timedOut {
                        lock.lock()
                        timedOut = true
                        lock.unlock()
                    }
                }
            }
        } else if titles.first == "hold" {
            started.signal()
            _ = gate.wait(timeout: .now() + 10)
        }
        if titles.first == "fail" { throw Refused() }
        return try RecordingStore.encodeLibrary(recordings)
    }

    var backgroundHoldTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    /// Lets every background encode through, the one held now included.
    /// Safe to call more than once.
    func openBackground() {
        lock.lock()
        let wasOpen = backgroundOpen
        backgroundOpen = true
        lock.unlock()
        if !wasOpen { backgroundGate.signal() }
    }

    /// Whether the held encode has begun.
    func waitUntilHeld() -> Bool {
        started.wait(timeout: .now() + 10) == .success
    }

    func release() {
        gate.signal()
    }
}

/// `recordings.json` writes are handed to a background writer (#406). These
/// pin what reaches the file, and in which order, once a write no longer
/// happens before the mutation returns.
@MainActor
final class RecordingLibraryWriterTests: XCTestCase {

    private var root: URL!
    private var file: URL { root.appendingPathComponent("recordings.json") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = TestSupport.makeTempRoot(label: "RecordingLibraryWriterTests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func library(_ titles: String...) -> [Recording] {
        titles.map { Recording(title: $0, source: .microphone, audioFileName: "\($0).wav") }
    }

    private func titlesOnDisk() throws -> [String] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Recording].self, from: Data(contentsOf: file)).map(\.title)
    }

    private func rowsOnDisk(of store: RecordingStore) throws -> [[String: Any]] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.storeURL))
                      as? [[String: Any]])
    }

    // MARK: - Writer

    func test_a_handed_off_write_is_on_disk_once_drained() throws {
        let writer = RecordingLibraryWriter()
        writer.enqueue(library("a", "b"), to: file)
        writer.drain()
        XCTAssertEqual(try titlesOnDisk(), ["a", "b"])
    }

    /// The point of coalescing: mutations made while a write is running cost
    /// one more encode between them, of the newest state, not one each.
    func test_a_burst_behind_a_running_write_is_encoded_once_with_the_newest_state() throws {
        let probe = EncodeProbe()
        let writer = RecordingLibraryWriter(encode: { try probe.encode($0) })
        writer.enqueue(library("hold"), to: file)
        XCTAssertTrue(probe.waitUntilHeld())

        writer.enqueue(library("one"), to: file)
        writer.enqueue(library("two"), to: file)
        writer.enqueue(library("three"), to: file)
        probe.release()
        writer.drain()

        XCTAssertEqual(probe.encoded, [["hold"], ["three"]])
        XCTAssertEqual(try titlesOnDisk(), ["three"])
    }

    /// A background encode that finishes after a newer synchronous write
    /// must not put the older contents back.
    func test_an_older_write_still_encoding_does_not_undo_a_synchronous_one() throws {
        let probe = EncodeProbe()
        let writer = RecordingLibraryWriter(encode: { try probe.encode($0) })
        writer.enqueue(library("hold"), to: file)
        XCTAssertTrue(probe.waitUntilHeld())

        XCTAssertTrue(writer.writeNow(library("now"), to: file))
        XCTAssertEqual(try titlesOnDisk(), ["now"], "on disk when writeNow returns")
        probe.release()
        writer.drain()

        XCTAssertEqual(try titlesOnDisk(), ["now"])
    }

    /// A snapshot still waiting in the queue is older than a synchronous
    /// write, so it is dropped rather than encoded for nothing.
    func test_a_synchronous_write_drops_an_older_queued_snapshot() throws {
        let probe = EncodeProbe()
        let writer = RecordingLibraryWriter(encode: { try probe.encode($0) })
        writer.enqueue(library("hold"), to: file)
        XCTAssertTrue(probe.waitUntilHeld())

        writer.enqueue(library("queued"), to: file)
        XCTAssertTrue(writer.writeNow(library("now"), to: file))
        probe.release()
        writer.drain()

        XCTAssertEqual(probe.encoded, [["hold"], ["now"]])
        XCTAssertEqual(try titlesOnDisk(), ["now"])
    }

    /// The bookkeeping `writeNow` clears must not swallow a write handed off
    /// after it.
    func test_a_write_handed_off_after_a_synchronous_one_still_happens() throws {
        let probe = EncodeProbe()
        let writer = RecordingLibraryWriter(encode: { try probe.encode($0) })
        writer.enqueue(library("hold"), to: file)
        XCTAssertTrue(probe.waitUntilHeld())

        writer.enqueue(library("queued"), to: file)
        XCTAssertTrue(writer.writeNow(library("now"), to: file))
        writer.enqueue(library("later"), to: file)
        probe.release()
        writer.drain()

        XCTAssertEqual(try titlesOnDisk(), ["later"])
    }

    func test_a_synchronous_write_that_fails_reports_it() {
        let writer = RecordingLibraryWriter()
        let unwritable = root.appendingPathComponent("missing-folder/recordings.json")
        XCTAssertFalse(writer.writeNow(library("a"), to: unwritable))
    }

    /// A failed synchronous write must not take the older snapshot queued
    /// behind it down too: that one holds changes handed off before it,
    /// which are not on disk either (a rename before an import that could
    /// not be saved, say).
    func test_a_failed_synchronous_write_keeps_the_snapshot_queued_before_it() throws {
        let probe = EncodeProbe()
        let writer = RecordingLibraryWriter(encode: { try probe.encode($0) })
        writer.enqueue(library("hold"), to: file)
        XCTAssertTrue(probe.waitUntilHeld())

        writer.enqueue(library("renamed"), to: file)
        XCTAssertFalse(writer.writeNow(library("fail"), to: file))
        probe.release()
        writer.drain()

        XCTAssertEqual(try titlesOnDisk(), ["renamed"])
    }

    /// Two spellings of one folder are one file, so the ordering holds
    /// across them: an older write through one spelling does not undo a
    /// newer one through the other.
    func test_the_ordering_holds_across_spellings_of_the_same_folder() throws {
        let link = root.appendingPathComponent("link", isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let probe = EncodeProbe()
        let writer = RecordingLibraryWriter(encode: { try probe.encode($0) })
        writer.enqueue(library("hold"), to: link.appendingPathComponent("recordings.json"))
        XCTAssertTrue(probe.waitUntilHeld())

        XCTAssertTrue(writer.writeNow(library("now"), to: real.appendingPathComponent("recordings.json")))
        probe.release()
        writer.drain()

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let onDisk = try decoder.decode([Recording].self,
                                        from: Data(contentsOf: real.appendingPathComponent("recordings.json")))
        XCTAssertEqual(onDisk.map(\.title), ["now"])
    }

    // MARK: - RecordingStore

    /// A store whose background writes are held until `probe.openBackground()`,
    /// so whatever is on disk got there before the call returned.
    private func storeWithHeldBackgroundWrites() -> (RecordingStore, EncodeProbe, RecordingLibraryWriter) {
        let probe = EncodeProbe(holdingBackgroundEncodes: true)
        let writer = RecordingLibraryWriter(encode: { try probe.encode($0) })
        return (RecordingStore(rootDirectory: root, writer: writer), probe, writer)
    }

    /// mila-mcp reads recordings.json. A recording the user just deleted must
    /// be gone from it when the call returns, not once a background encode
    /// gets to it — so the deletions write synchronously. The background
    /// writes are held throughout, so a deletion that went back to
    /// `persist()` would leave nothing on disk here.
    func test_deletions_are_on_disk_when_the_call_returns() throws {
        let (store, probe, writer) = storeWithHeldBackgroundWrites()
        defer {  // if an assertion below throws
            probe.openBackground()
            writer.drain()
        }
        let keep = Recording(title: "keep", source: .microphone, audioFileName: "keep.wav")
        let gone = Recording(title: "gone", source: .microphone, audioFileName: "gone.wav")
        store.add(keep)
        store.add(gone)
        XCTAssertTrue(probe.waitUntilHeld())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storeURL.path),
                       "the adds are background writes, held")

        store.softDelete(gone)
        let trashedRow = try XCTUnwrap(rowsOnDisk(of: store).first { $0["title"] as? String == "gone" })
        XCTAssertNotNil(trashedRow["deletedAt"], "Recently Deleted is not on disk yet")

        store.permanentlyDelete(try XCTUnwrap(store.recordings.first { $0.id == gone.id }))
        XCTAssertEqual(try rowsOnDisk(of: store).compactMap { $0["title"] as? String }, ["keep"])

        store.softDelete(keep)
        XCTAssertEqual(store.emptyTrash(), 1)
        XCTAssertTrue(try rowsOnDisk(of: store).isEmpty)

        // Stop on a queued transcription moves it to Recently Deleted too.
        let stopped = Recording(title: "stopped", source: .microphone, audioFileName: "stopped.wav")
        store.add(stopped)
        store.stopTranscription(stopped)
        let stoppedRow = try XCTUnwrap(rowsOnDisk(of: store).first { $0["title"] as? String == "stopped" })
        XCTAssertNotNil(stoppedRow["deletedAt"], "a stopped transcription is not in Recently Deleted on disk yet")
        XCTAssertFalse(probe.backgroundHoldTimedOut, "a background hold ran out, so the test did not run against held writes")

        // The held write is older than all of that, so letting it finish
        // must not put the deleted rows back.
        probe.openBackground()
        writer.drain()
        let rows = try rowsOnDisk(of: store)
        XCTAssertEqual(rows.compactMap { $0["title"] as? String }, ["stopped"])
        XCTAssertNotNil(rows.first?["deletedAt"])
    }

    /// `update` reports whether a separate process now reads the new row
    /// (the live sidecar's `completed` handoff depends on it), so a `true`
    /// has to mean the row is already in the file.
    func test_update_is_on_disk_when_it_reports_success() throws {
        let (store, probe, writer) = storeWithHeldBackgroundWrites()
        defer {
            probe.openBackground()
            writer.drain()
        }
        var rec = Recording(title: "before", source: .microphone, audioFileName: "a.wav")
        store.add(rec)
        XCTAssertTrue(probe.waitUntilHeld())
        rec.title = "after"

        XCTAssertTrue(store.update(rec))
        XCTAssertEqual(try rowsOnDisk(of: store).compactMap { $0["title"] as? String }, ["after"])
        XCTAssertFalse(probe.backgroundHoldTimedOut, "a background hold ran out, so the test did not run against held writes")
    }

    /// A rename is handed off, and a store opened on the same folder (a
    /// relaunch, a relocate back) still reads it: `load()` waits for it.
    func test_a_handed_off_change_is_read_back_by_the_next_load() {
        let store = RecordingStore(rootDirectory: root)
        let rec = Recording(title: "before", source: .microphone, audioFileName: "a.wav")
        store.add(rec)
        store.rename(rec, to: "after")

        let relaunched = RecordingStore(rootDirectory: root)
        XCTAssertEqual(relaunched.recordings.map(\.title), ["after"])
    }
}
