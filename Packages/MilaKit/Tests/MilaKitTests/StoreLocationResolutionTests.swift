import XCTest
@testable import MilaKit

/// REGRESSION (CodeRabbit on #183, Major — "keep `store-location.json`
/// synchronized after relocation failures"):
///
/// `RecordingStore.relocateRecordings(to:)` switches the live store paths
/// BEFORE writing the pointer, and relocation deliberately leaves the old
/// store on disk. So a pointer write that fails leaves a perfectly readable
/// `store-location.json` naming a store the app has stopped writing to —
/// and mila-mcp answers from it. That is worse than answering nothing: it is
/// confidently wrong, with no signal to the user.
///
/// The first test pins that the hazard is real (a stale pointer really does
/// serve the old recordings). The rest pin the check the app now runs after
/// every pointer write, which is what closes the MCP gate.
final class StoreLocationResolutionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreLocationResolutionTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Recordings", isDirectory: true),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeStore(_ titles: [String], at storeFile: URL) throws {
        let recordings = titles.map {
            StoredRecording(title: $0, createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                            audioFileName: "\($0).wav")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: storeFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(recordings).write(to: storeFile)
    }

    /// A relocated directory the app is now using, and the old default-layout
    /// store still sitting where it always was.
    private func relocatedLayout() throws -> (newDir: URL, newStore: URL, oldStore: URL) {
        let newDir = root.appendingPathComponent("Relocated", isDirectory: true)
        let newStore = newDir.appendingPathComponent("recordings.json")
        let oldStore = root.appendingPathComponent("recordings.json")
        try writeStore(["after relocation"], at: newStore)
        try writeStore(["before relocation"], at: oldStore)
        return (newDir, newStore, oldStore)
    }

    // MARK: - The hazard

    /// The bug, demonstrated: with the pointer still naming the old store,
    /// a reader serves recordings the app has stopped writing to.
    func test_a_stale_pointer_makes_the_reader_serve_the_old_store() throws {
        let layout = try relocatedLayout()
        // The pointer the failed write left behind — still the pre-relocation one.
        try StoreLocationPointer(
            recordingsDirectory: root.appendingPathComponent("Recordings").path,
            storeFile: layout.oldStore.path,
            updatedAt: Date()).write(to: root)

        let served = try MilaStoreReader(root: root).listRecordings().map(\.title)
        XCTAssertEqual(served, ["before relocation"],
                       "precondition for the whole fix: a stale pointer really does serve stale data")

        XCTAssertFalse(MilaStoreReader.resolvesActiveStore(root: root,
                                                          recordingsDirectory: layout.newDir,
                                                          storeFile: layout.newStore),
                       "the app must be able to detect exactly this state")
    }

    /// The other route into the same shape: the very first pointer write
    /// fails, so there is no pointer at all and the reader falls back to the
    /// default layout — which, after a relocation, is also the OLD store.
    /// Absence is not safety here.
    func test_a_missing_pointer_after_relocation_is_also_a_mismatch() throws {
        let layout = try relocatedLayout()
        XCTAssertNil(StoreLocationPointer.read(from: root), "no pointer on disk")

        let served = try MilaStoreReader(root: root).listRecordings().map(\.title)
        XCTAssertEqual(served, ["before relocation"])

        XCTAssertFalse(MilaStoreReader.resolvesActiveStore(root: root,
                                                          recordingsDirectory: layout.newDir,
                                                          storeFile: layout.newStore))
    }

    // MARK: - The check

    /// A pointer that names the active store passes — this is the successful
    /// relocation, which must behave exactly as it always has.
    func test_a_current_pointer_after_relocation_resolves_the_active_store() throws {
        let layout = try relocatedLayout()
        try StoreLocationPointer(recordingsDirectory: layout.newDir.path,
                                 storeFile: layout.newStore.path,
                                 updatedAt: Date()).write(to: root)

        XCTAssertTrue(MilaStoreReader.resolvesActiveStore(root: root,
                                                          recordingsDirectory: layout.newDir,
                                                          storeFile: layout.newStore))
        let served = try MilaStoreReader(root: root).listRecordings().map(\.title)
        XCTAssertEqual(served, ["after relocation"])
    }

    /// The back-compat case the fallback exists for, and the reason the check
    /// is "what does a reader resolve?" rather than "does a pointer exist?":
    /// on the DEFAULT layout with no pointer, the fallback lands correctly, so
    /// this must NOT be reported as a mismatch. Reporting it would disable MCP
    /// for every user whose setup is fine.
    func test_missing_pointer_on_the_default_layout_is_not_a_mismatch() throws {
        XCTAssertNil(StoreLocationPointer.read(from: root))
        XCTAssertTrue(MilaStoreReader.resolvesActiveStore(
            root: root,
            recordingsDirectory: root.appendingPathComponent("Recordings", isDirectory: true),
            storeFile: root.appendingPathComponent("recordings.json")))
    }

    /// Paths are compared with symlinks resolved on BOTH sides — macOS temp
    /// roots live behind `/var` → `/private/var`, and a spurious mismatch
    /// there would disable MCP access for no reason.
    func test_symlinked_paths_compare_equal() throws {
        let recordings = root.appendingPathComponent("Recordings", isDirectory: true)
        let storeFile = root.appendingPathComponent("recordings.json")
        try StoreLocationPointer(recordingsDirectory: recordings.path,
                                 storeFile: storeFile.path,
                                 updatedAt: Date()).write(to: root)

        // Same locations, spelled through the symlink and with a redundant
        // `.` component the standardizer removes.
        let viaSymlink = URL(fileURLWithPath: recordings.resolvingSymlinksInPath().path + "/.",
                             isDirectory: true)
        XCTAssertTrue(MilaStoreReader.resolvesActiveStore(
            root: root,
            recordingsDirectory: viaSymlink,
            storeFile: URL(fileURLWithPath: storeFile.resolvingSymlinksInPath().path)))
    }

    /// A malformed pointer reads as absent, so the verdict is the fallback's:
    /// correct on the default layout, a mismatch once relocated.
    func test_malformed_pointer_falls_back_and_is_judged_on_the_fallback() throws {
        try Data("not json".utf8)
            .write(to: root.appendingPathComponent(StoreLocationPointer.fileName))
        let layout = try relocatedLayout()

        XCTAssertTrue(MilaStoreReader.resolvedLocation(root: root).usedFallback)
        XCTAssertFalse(MilaStoreReader.resolvesActiveStore(root: root,
                                                           recordingsDirectory: layout.newDir,
                                                           storeFile: layout.newStore))
    }
}
