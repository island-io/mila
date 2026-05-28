import XCTest
@testable import Mila

@MainActor
final class RecordingStorageSettingsTests: XCTestCase {

    private var tempRoot: URL!
    private var defaultsSuiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MilaStorageTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defaultsSuiteName = "RecordingStorageSettingsTests.\(UUID())"
        defaults = UserDefaults(suiteName: defaultsSuiteName)
    }

    override func tearDown() async throws {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        if let defaultsSuiteName { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        try await super.tearDown()
    }

    // MARK: - RecordingStorageSettings

    func test_settings_starts_with_no_custom_directory_by_default() {
        let settings = RecordingStorageSettings(defaults: defaults)
        XCTAssertNil(settings.customDirectory)
    }

    func test_setDirectory_persists_bookmark_and_resolves_on_relaunch() throws {
        let chosen = tempRoot.appendingPathComponent("ChosenFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        let first = RecordingStorageSettings(defaults: defaults)
        XCTAssertTrue(first.setDirectory(chosen),
                      "setDirectory should succeed when the URL is a real directory")
        XCTAssertEqual(first.customDirectory?.standardizedFileURL,
                       chosen.standardizedFileURL)

        // Fresh instance — same defaults suite, should pick up the
        // bookmark and resolve it back to the same path.
        let second = RecordingStorageSettings(defaults: defaults)
        XCTAssertEqual(second.customDirectory?.standardizedFileURL,
                       chosen.standardizedFileURL)
    }

    func test_clearDirectory_removes_the_override() throws {
        let chosen = tempRoot.appendingPathComponent("ToBeCleared", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        let settings = RecordingStorageSettings(defaults: defaults)
        XCTAssertTrue(settings.setDirectory(chosen))
        XCTAssertNotNil(settings.customDirectory)

        settings.clearDirectory()
        XCTAssertNil(settings.customDirectory)
        XCTAssertNil(defaults.data(forKey: RecordingStorageSettings.bookmarkKey))
    }

    func test_resolution_falls_back_to_default_when_folder_was_deleted() throws {
        let chosen = tempRoot.appendingPathComponent("WillBeDeleted", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)

        let first = RecordingStorageSettings(defaults: defaults)
        XCTAssertTrue(first.setDirectory(chosen))

        // Simulate the user (or an external process) deleting the
        // folder while the app wasn't running. Bookmark resolution
        // can still succeed (the underlying inode reference may
        // resolve to a phantom path), but our existence check should
        // catch the empty path and fall back.
        try FileManager.default.removeItem(at: chosen)

        let second = RecordingStorageSettings(defaults: defaults)
        XCTAssertNil(second.customDirectory,
                     "Stale bookmarks pointing at deleted folders must surface as nil so the store falls back to default")
    }

    // MARK: - RecordingStore.relocateRecordings

    func test_store_relocate_routes_new_recordings_to_new_directory() throws {
        let alternative = tempRoot.appendingPathComponent("Alt", isDirectory: true)
        try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)

        let appSupport = tempRoot.appendingPathComponent("AppSupport-\(UUID())", isDirectory: true)
        let store = RecordingStore(rootDirectory: appSupport)

        // Default location: a freshAudioURL lives inside the default
        // Recordings/ subdir.
        let defaultURL = store.freshAudioURL(suggestedName: "Before")
        XCTAssertTrue(defaultURL.path.hasPrefix(store.defaultRecordingsDirectory.path))

        // Relocate.
        store.relocateRecordings(to: alternative)
        XCTAssertEqual(store.recordingsDirectory.standardizedFileURL,
                       alternative.standardizedFileURL)

        let newURL = store.freshAudioURL(suggestedName: "After")
        XCTAssertTrue(newURL.path.hasPrefix(alternative.path),
                      "After relocate, fresh audio URLs must live under the new directory")
    }

    func test_store_relocate_reads_existing_recordings_json_in_new_directory() throws {
        let appSupport = tempRoot.appendingPathComponent("AppSupport-\(UUID())", isDirectory: true)
        let alternative = tempRoot.appendingPathComponent("AltDir", isDirectory: true)
        try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)

        // Pre-seed the alternative directory with a Mila-style
        // recordings.json so the store picks it up on relocate.
        let seeded = Recording(title: "Pre-existing",
                               duration: 1.0,
                               source: .microphone,
                               audioFileName: "seeded.wav")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([seeded])
        let altStoreURL = alternative.appendingPathComponent("recordings.json")
        try data.write(to: altStoreURL)

        let store = RecordingStore(rootDirectory: appSupport)
        XCTAssertTrue(store.recordings.isEmpty)
        store.relocateRecordings(to: alternative)
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.recordings.first?.title, "Pre-existing")
    }

    func test_store_relocate_to_nil_returns_to_default_layout() throws {
        let appSupport = tempRoot.appendingPathComponent("AppSupport-\(UUID())", isDirectory: true)
        let alternative = tempRoot.appendingPathComponent("Alt2", isDirectory: true)
        try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)

        let store = RecordingStore(rootDirectory: appSupport)
        store.relocateRecordings(to: alternative)
        XCTAssertNotEqual(store.recordingsDirectory.standardizedFileURL,
                          store.defaultRecordingsDirectory.standardizedFileURL)

        store.relocateRecordings(to: nil)
        XCTAssertEqual(store.recordingsDirectory.standardizedFileURL,
                       store.defaultRecordingsDirectory.standardizedFileURL)
    }

    func test_init_with_custom_directory_loads_from_that_directory() throws {
        let appSupport = tempRoot.appendingPathComponent("AppSupport-\(UUID())", isDirectory: true)
        let alternative = tempRoot.appendingPathComponent("Alt3", isDirectory: true)
        try FileManager.default.createDirectory(at: alternative, withIntermediateDirectories: true)

        let seeded = Recording(title: "FromAlt",
                               duration: 1.0,
                               source: .microphone,
                               audioFileName: "x.wav")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode([seeded])
        try data.write(to: alternative.appendingPathComponent("recordings.json"))

        let store = RecordingStore(rootDirectory: appSupport,
                                   customRecordingsDirectory: alternative)
        XCTAssertEqual(store.recordingsDirectory.standardizedFileURL,
                       alternative.standardizedFileURL)
        XCTAssertEqual(store.recordings.map(\.title), ["FromAlt"])
    }
}
