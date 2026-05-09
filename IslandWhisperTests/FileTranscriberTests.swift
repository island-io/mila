import XCTest
import AVFoundation
@testable import IslandWhisper

@MainActor
final class FileTranscriberTests: XCTestCase {

    private var tempRoot: URL!
    private var store: RecordingStore!

    override func setUp() {
        super.setUp()
        tempRoot = TestSupport.makeTempRoot(label: "FileTranscriberTests")
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = RecordingStore(rootDirectory: tempRoot)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        super.tearDown()
    }

    func test_imports_a_stereo_48k_wav_and_reencodes_to_mono_16k() async throws {
        let source = tempRoot.appendingPathComponent("source.wav")
        try TestSupport.writeStereo48kSineWav(at: source, durationSeconds: 1.0)

        let recording = try await FileTranscriber.importFile(at: source, into: store)

        XCTAssertEqual(recording.title, "source")
        XCTAssertEqual(recording.source, .systemAudio)
        XCTAssertEqual(recording.status, .pending)
        XCTAssertEqual(recording.duration, 1.0, accuracy: 0.05)

        let destURL = store.audioURL(for: recording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destURL.path))

        let outFile = try AVAudioFile(forReading: destURL)
        XCTAssertEqual(outFile.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(outFile.processingFormat.channelCount, 1)
        XCTAssertGreaterThan(outFile.length, Int64(15_000),
                             "Expected ~16k frames after downsample")
    }

    func test_imports_a_mono_16k_wav_unchanged() async throws {
        let source = tempRoot.appendingPathComponent("native.wav")
        try TestSupport.writeSineWav(at: source, durationSeconds: 0.5)

        let recording = try await FileTranscriber.importFile(at: source, into: store)
        XCTAssertEqual(recording.duration, 0.5, accuracy: 0.05)

        let outFile = try AVAudioFile(forReading: store.audioURL(for: recording))
        XCTAssertEqual(outFile.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(outFile.processingFormat.channelCount, 1)
    }

    func test_import_error_throws_for_missing_file() async {
        let bogus = tempRoot.appendingPathComponent("missing.wav")
        do {
            _ = try await FileTranscriber.importFile(at: bogus, into: store)
            XCTFail("Expected importing a missing file to throw")
        } catch {
            // expected
        }
    }

    func test_allowed_extensions_includes_common_audio_formats() {
        let exts = Set(FileTranscriber.allowedExtensions)
        for required in ["wav", "mp3", "m4a", "mp4", "mov"] {
            XCTAssertTrue(exts.contains(required),
                          "Expected \(required) in allowedExtensions")
        }
    }
}
