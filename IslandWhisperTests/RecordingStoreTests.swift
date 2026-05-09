import XCTest
@testable import IslandWhisper

@MainActor
final class RecordingStoreTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("IslandWhisperTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        super.tearDown()
    }

    func test_store_persists_recordings_across_instances() throws {
        let first = RecordingStore(rootDirectory: tempRoot)
        XCTAssertTrue(first.recordings.isEmpty)

        let recording = Recording(
            title: "Fixture",
            duration: 3.14,
            source: .microphone,
            audioFileName: "fixture.wav"
        )
        first.add(recording)
        XCTAssertEqual(first.recordings.count, 1)

        let second = RecordingStore(rootDirectory: tempRoot)
        XCTAssertEqual(second.recordings.count, 1)
        XCTAssertEqual(second.recordings.first?.id, recording.id)

        second.permanentlyDelete(recording)

        let third = RecordingStore(rootDirectory: tempRoot)
        XCTAssertTrue(third.recordings.isEmpty)
    }

    func test_soft_delete_moves_to_recently_deleted_and_restore_returns_it() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let rec = Recording(title: "X", source: .microphone, audioFileName: "x.wav")
        store.add(rec)

        XCTAssertTrue(store.recordings(in: .transcriptions).contains { $0.id == rec.id })
        XCTAssertFalse(store.recordings(in: .recentlyDeleted).contains { $0.id == rec.id })

        store.softDelete(rec)
        XCTAssertFalse(store.recordings(in: .transcriptions).contains { $0.id == rec.id })
        XCTAssertTrue(store.recordings(in: .recentlyDeleted).contains { $0.id == rec.id })

        if let trashed = store.recordings.first(where: { $0.id == rec.id }) {
            store.restore(trashed)
        }
        XCTAssertTrue(store.recordings(in: .transcriptions).contains { $0.id == rec.id })
        XCTAssertFalse(store.recordings(in: .recentlyDeleted).contains { $0.id == rec.id })
    }

    func test_recordings_in_category_classifies_correctly() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let mic = Recording(title: "Voice Memo · Today", source: .microphone, audioFileName: "a.wav")
        let dictation = Recording(title: "Dictation · Today", source: .microphone, audioFileName: "b.wav")
        let meeting = Recording(title: "Standup", source: .meeting, audioFileName: "c.wav")
        store.add(mic); store.add(dictation); store.add(meeting)

        XCTAssertEqual(store.recordings(in: .transcriptions).count, 3)
        XCTAssertEqual(store.recordings(in: .meetings).map(\.id), [meeting.id])
        XCTAssertEqual(store.recordings(in: .dictations).map(\.id), [dictation.id])
        XCTAssertEqual(store.recordings(in: .recentlyDeleted).count, 0)
    }

    func test_fresh_audio_url_is_unique_under_recordings_directory() {
        let store = RecordingStore(rootDirectory: tempRoot)
        let a = store.freshAudioURL(suggestedName: "Hello")
        let b = store.freshAudioURL(suggestedName: "Hello")

        XCTAssertEqual(a.pathExtension, "wav")
        XCTAssertTrue(a.path.contains("Recordings"))
        XCTAssertTrue(a.lastPathComponent.hasPrefix("Hello "))
        XCTAssertNotEqual(a.lastPathComponent, b.lastPathComponent)
    }

    func test_creating_store_creates_models_and_recordings_dirs() {
        _ = RecordingStore(rootDirectory: tempRoot)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("Recordings").path,
            isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempRoot.appendingPathComponent("Models").path,
            isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }
}
