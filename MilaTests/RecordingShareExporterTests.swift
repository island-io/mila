import XCTest
import TranscriptionCore
@testable import Mila

@MainActor
final class RecordingShareExporterTests: XCTestCase {

    private var root: URL!
    private var store: RecordingStore!

    override func setUp() async throws {
        try await super.setUp()
        root = TestSupport.makeTempRoot(label: "RecordingShareExporterTests")
        store = RecordingStore(rootDirectory: root)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    /// A completed, diarized recording with a real (tiny) WAV on disk.
    private func makeCompletedRecording(title: String = "Weekly sync") throws -> Recording {
        let audioURL = store.freshAudioURL(suggestedName: title)
        try TestSupport.writeSineWav(at: audioURL, durationSeconds: 0.2)
        let recording = Recording(
            title: title, createdAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 0.2,
            source: .meeting, audioFileName: audioURL.lastPathComponent, status: .completed,
            language: "en",
            segments: [TranscriptSegment(start: 0, end: 0.1, text: "hello", speaker: "SPEAKER_00"),
                       TranscriptSegment(start: 0.1, end: 0.2, text: "hi", speaker: "SPEAKER_01")],
            fullText: "hello hi", summary: "Short.",
            speakerNames: ["SPEAKER_00": "Daniel", "SPEAKER_01": "Ada"])
        store.add(recording)
        return recording
    }

    private func unzipped(_ archive: URL) async throws -> URL {
        let out = root.appendingPathComponent("unzipped-\(UUID().uuidString)", isDirectory: true)
        try await ZipArchiver.unzip(archive, into: out)
        return out
    }

    func test_bundle_has_exactly_the_three_fixed_entries_and_a_matching_manifest() async throws {
        let recording = try makeCompletedRecording()
        let archive = try await RecordingShareExporter.buildBundle(
            for: recording, store: store, exportedBy: "Ada Lovelace",
            now: Date(timeIntervalSince1970: 1_700_100_000),
            appInfo: .init(version: "1.9.6", build: "68"))
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        XCTAssertEqual(archive.pathExtension, ShareManifest.fileExtension)
        XCTAssertEqual(archive.lastPathComponent, "Weekly sync.milashare")

        let out = try await unzipped(archive)
        let entries = Set(try FileManager.default.contentsOfDirectory(atPath: out.path))
        XCTAssertEqual(entries, ["manifest.json", "audio.wav", "transcript.txt"])

        let manifest = try ShareManifest.decode(
            try Data(contentsOf: out.appendingPathComponent("manifest.json"))).validated()
        XCTAssertEqual(manifest.version, ShareManifest.currentVersion)
        XCTAssertEqual(manifest.exportedBy.name, "Ada Lovelace")
        XCTAssertEqual(manifest.app?.version, "1.9.6")
        XCTAssertEqual(manifest.recording.id, recording.id)
        XCTAssertEqual(manifest.recording.speakerNames, ["SPEAKER_00": "Daniel", "SPEAKER_01": "Ada"])
        XCTAssertEqual(manifest.recording.summary, "Short.")
        XCTAssertEqual(manifest.audio.fileName, "audio.wav")
        XCTAssertEqual(manifest.audio.format, "wav")
        XCTAssertNil(manifest.speakerProfiles, "no profiles were passed, so the key is absent")

        let audio = out.appendingPathComponent("audio.wav")
        let size = try XCTUnwrap(try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(manifest.audio.byteCount, Int64(size))
        XCTAssertEqual(manifest.audio.sha256, try FileDigest.sha256Hex(of: audio))
        XCTAssertEqual(try FileDigest.sha256Hex(of: audio),
                       try FileDigest.sha256Hex(of: store.audioURL(for: recording)),
                       "audio is copied as-is, never re-encoded")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("transcript.txt"), encoding: .utf8),
                       "hello hi")
    }

    func test_voice_profiles_are_written_only_when_passed_and_carry_the_model_stamp() async throws {
        let recording = try makeCompletedRecording()
        let profiles = [SharedSpeakerProfile(name: "Daniel", embedding: [0.5, 0.5], sampleCount: 2,
                                             embeddingModel: SpeakerEmbeddingModel.current.id)]
        let archive = try await RecordingShareExporter.buildBundle(
            for: recording, store: store, profiles: profiles, exportedBy: "Ada")
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
        let out = try await unzipped(archive)
        let manifest = try ShareManifest.decode(
            try Data(contentsOf: out.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.speakerProfiles?.count, 1)
        XCTAssertEqual(manifest.speakerProfiles?.first?.embeddingModel, SpeakerEmbeddingModel.current.id)
    }

    func test_canExport_requires_a_completed_untrashed_transcribed_recording() {
        var r = Recording(title: "x", source: .microphone, audioFileName: "x.wav", status: .completed,
                          segments: [TranscriptSegment(start: 0, end: 1, text: "t")])
        XCTAssertTrue(RecordingShareExporter.canExport(r))
        r.status = .pending
        XCTAssertFalse(RecordingShareExporter.canExport(r))
        r.status = .completed
        r.deletedAt = Date()
        XCTAssertFalse(RecordingShareExporter.canExport(r))
        r.deletedAt = nil
        r.segments = []
        r.fullText = ""
        XCTAssertFalse(RecordingShareExporter.canExport(r), "nothing to share without a transcript")
        r.fullText = "plain text only"
        XCTAssertTrue(RecordingShareExporter.canExport(r))
    }

    func test_suggested_file_name_is_filesystem_safe() {
        let r = Recording(title: "Q3: board/call?", source: .meeting, audioFileName: "a.wav")
        let name = RecordingShareExporter.suggestedFileName(for: r)
        XCTAssertTrue(name.hasSuffix(".milashare"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        let blank = Recording(title: "   ", source: .meeting, audioFileName: "a.wav")
        XCTAssertEqual(RecordingShareExporter.suggestedFileName(for: blank), "Shared recording.milashare")
    }

    func test_missing_audio_and_untranscribed_recordings_are_refused() async throws {
        let recording = try makeCompletedRecording()
        try FileManager.default.removeItem(at: store.audioURL(for: recording))
        do {
            _ = try await RecordingShareExporter.buildBundle(for: recording, store: store, exportedBy: "A")
            XCTFail("expected audioMissing")
        } catch let error as RecordingShareExporter.ExportError {
            XCTAssertEqual(error, .audioMissing)
        }

        var pending = recording
        pending.status = .pending
        do {
            _ = try await RecordingShareExporter.buildBundle(for: pending, store: store, exportedBy: "A")
            XCTFail("expected notTranscribed")
        } catch let error as RecordingShareExporter.ExportError {
            XCTAssertEqual(error, .notTranscribed)
        }
    }

    func test_exporter_name_prefers_the_user_default_and_falls_back_to_the_account_name() {
        let suiteName = "RecordingShareExporterTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertFalse(RecordingShareExporter.exporterName(defaults: defaults).isEmpty)
        defaults.set("  Ada L.  ", forKey: RecordingShareExporter.exporterNameKey)
        XCTAssertEqual(RecordingShareExporter.exporterName(defaults: defaults), "Ada L.")
    }
}
