import XCTest
import TranscriptionCore
@testable import Mila

/// Two libraries on one Mac: store A exports, store B imports. Every test
/// goes through the real exporter, the real zip, and the real importer, so
/// what is pinned is the end-to-end contract — not a mock's idea of it.
@MainActor
final class RecordingShareImporterTests: XCTestCase {

    private var rootA: URL!
    private var rootB: URL!
    private var storeA: RecordingStore!
    private var storeB: RecordingStore!
    private var scratch: URL!
    private var suiteNames: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        rootA = TestSupport.makeTempRoot(label: "RecordingShareImporterTests-A")
        rootB = TestSupport.makeTempRoot(label: "RecordingShareImporterTests-B")
        scratch = TestSupport.makeTempRoot(label: "RecordingShareImporterTests-scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        storeA = RecordingStore(rootDirectory: rootA)
        storeB = RecordingStore(rootDirectory: rootB)
    }

    override func tearDown() async throws {
        for url in [rootA, rootB, scratch] { try? FileManager.default.removeItem(at: url!) }
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeCompletedRecording(in store: RecordingStore,
                                        title: String = "Weekly sync",
                                        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
                                        speakerNames: [String: String] = ["SPEAKER_00": "Daniel", "SPEAKER_01": "Ada"]
    ) throws -> Recording {
        let audioURL = store.freshAudioURL(suggestedName: title)
        try TestSupport.writeSineWav(at: audioURL, durationSeconds: 0.2)
        let recording = Recording(
            title: title, createdAt: createdAt, duration: 0.2, source: .meeting,
            audioFileName: audioURL.lastPathComponent, status: .completed, language: "en",
            segments: [TranscriptSegment(start: 0, end: 0.1, text: "hello", speaker: "SPEAKER_00"),
                       TranscriptSegment(start: 0.1, end: 0.2, text: "hi", speaker: "SPEAKER_01")],
            fullText: "hello hi", summary: "Short.", speakerNames: speakerNames)
        store.add(recording)
        return recording
    }

    private func export(_ recording: Recording, from store: RecordingStore,
                        profiles: [SharedSpeakerProfile] = []) async throws -> URL {
        let built = try await RecordingShareExporter.buildBundle(
            for: recording, store: store, profiles: profiles, exportedBy: "Ada Lovelace",
            now: Date(timeIntervalSince1970: 1_700_100_000))
        let dest = scratch.appendingPathComponent("\(UUID().uuidString).milashare")
        try FileManager.default.moveItem(at: built, to: dest)
        try? FileManager.default.removeItem(at: built.deletingLastPathComponent())
        return dest
    }

    private func makeImporter(storage: RecordingStorageSettings? = nil,
                              profiles: SpeakerProfileStore? = nil,
                              voice: VoiceRecognitionSettings? = nil,
                              threshold: Double = 0.55,
                              busy: @escaping (UUID) -> Bool = { _ in false }) -> RecordingShareImporter {
        RecordingShareImporter(store: storeB, storageSettings: storage, profileStore: profiles,
                               voiceRecognition: voice, similarityThreshold: { threshold },
                               speakerDirectory: SpeakerDirectory(directory: rootB),
                               isRecordingBusy: busy,
                               // Keep the audio filename stable for the assertions below.
                               compressImportedWAV: false)
    }

    private func makeVoiceSettings(enabled: Bool, ready: Bool = true) -> VoiceRecognitionSettings {
        let name = "RecordingShareImporterTests.\(UUID())"
        suiteNames.append(name)
        let settings = VoiceRecognitionSettings(defaults: UserDefaults(suiteName: name)!)
        settings.diarizationReady = { ready }
        settings.isEnabled = enabled
        return settings
    }

    private func makeStorageSettings(limitBytes: Int64) -> RecordingStorageSettings {
        let name = "RecordingShareImporterTests.storage.\(UUID())"
        suiteNames.append(name)
        let settings = RecordingStorageSettings(defaults: UserDefaults(suiteName: name)!)
        settings.limitBytes = limitBytes
        return settings
    }

    /// Staging is asynchronous (unzip + hash off the main actor). Wait for
    /// either outcome.
    private func stage(_ url: URL, with importer: RecordingShareImporter,
                       file: StaticString = #filePath, line: UInt = #line) async {
        importer.handleOpen(url)
        for _ in 0..<400 where importer.pending == nil && importer.errorMessage == nil {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(importer.pending != nil || importer.errorMessage != nil,
                      "staging never finished", file: file, line: line)
    }

    private func zipDirectory(_ dir: URL) async throws -> URL {
        let archive = scratch.appendingPathComponent("\(UUID().uuidString).milashare")
        try await ZipArchiver.zipContents(of: dir, to: archive)
        return archive
    }

    private var sha256OfEmpty: String { String(repeating: "e3", count: 32) }

    private func hostileManifestJSON(audioFileName: String, version: Int = 1,
                                     byteCount: Int64 = 44, sha: String? = nil) -> String {
        """
        { "version": \(version), "bundleID": "11111111-2222-3333-4444-555555555555",
          "exportedAt": "2026-10-06T00:00:00Z", "exportedBy": { "name": "Mallory" },
          "recording": { "id": "22222222-2222-3333-4444-555555555555", "title": "Evil",
                         "createdAt": "2026-10-01T00:00:00Z", "duration": 1,
                         "segments": [ { "start": 0, "end": 1, "text": "boo" } ] },
          "audio": { "fileName": "\(audioFileName)", "format": "wav", "byteCount": \(byteCount),
                     "sha256": "\(sha ?? sha256OfEmpty)" } }
        """
    }

    private func recordingsDirectoryNames(_ store: RecordingStore) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: store.recordingsDirectory.path)) ?? [])
    }

    // MARK: - Fresh add

    func test_fresh_import_adds_the_recording_with_attribution_audio_and_sidecars() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let bundle = try await export(original, from: storeA)
        let importer = makeImporter()

        await stage(bundle, with: importer)
        let pending = try XCTUnwrap(importer.pending)
        XCTAssertEqual(pending.disposition, .add)
        XCTAssertFalse(pending.wouldExceedStorageCap)
        XCTAssertTrue(pending.speakerPlan.isEmpty)
        XCTAssertEqual(pending.manifest.recording.title, "Weekly sync")

        await importer.confirm()
        XCTAssertNil(importer.pending)
        XCTAssertNil(importer.errorMessage)
        XCTAssertEqual(importer.lastImport?.recordingID, original.id)

        let imported = try XCTUnwrap(storeB.recordings.first { $0.id == original.id })
        XCTAssertEqual(imported.title, "Weekly sync")
        XCTAssertEqual(imported.status, .completed)
        XCTAssertFalse(imported.isTrashed)
        XCTAssertNil(imported.folder)
        XCTAssertEqual(imported.sharedBy, "Ada Lovelace")
        XCTAssertEqual(imported.sharedAt, Date(timeIntervalSince1970: 1_700_100_000))
        XCTAssertEqual(imported.speakerNames, ["SPEAKER_00": "Daniel", "SPEAKER_01": "Ada"])
        XCTAssertEqual(imported.fullText, "hello hi")
        XCTAssertEqual(imported.summary, "Short.")
        XCTAssertEqual(imported.segments.count, 2)
        XCTAssertNotEqual(imported.audioFileName, original.audioFileName,
                          "the receiver mints its own filename")
        XCTAssertTrue(imported.audioFileName.hasSuffix(".wav") || imported.audioFileName.hasSuffix(".m4a"))

        let names = recordingsDirectoryNames(storeB)
        XCTAssertTrue(names.contains(imported.transcriptFileName), "\(names)")
        XCTAssertTrue(names.contains(imported.subtitleFileName), "\(names)")
        XCTAssertTrue(names.contains(imported.summaryFileName), "\(names)")
        XCTAssertFalse(names.contains { $0.hasSuffix(".partial") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.stagingDirectory.path),
                       "staging must be cleaned up")

        // Relaunch B: the record survives, nothing is "recovered" as a phantom.
        let relaunched = RecordingStore(rootDirectory: rootB)
        XCTAssertEqual(relaunched.recordings.map(\.id), [original.id])
    }

    func test_imported_recording_is_slotted_by_its_own_creation_date() async throws {
        // `add` inserts at the top, so add oldest first to get a newest-first list.
        _ = try makeCompletedRecording(in: storeB, title: "Oldest here",
                                       createdAt: Date(timeIntervalSince1970: 1_600_000_000))
        _ = try makeCompletedRecording(in: storeB, title: "Newest here",
                                       createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let shared = try makeCompletedRecording(in: storeA, title: "From Ada",
                                                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        let importer = makeImporter()
        await stage(try await export(shared, from: storeA), with: importer)
        await importer.confirm()
        XCTAssertEqual(storeB.recordings.map(\.title), ["Newest here", "From Ada", "Oldest here"])
    }

    // MARK: - Update by UUID

    func test_reimporting_the_same_bundle_updates_rather_than_duplicates() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let bundle = try await export(original, from: storeA)
        let importer = makeImporter()
        await stage(bundle, with: importer)
        await importer.confirm()
        XCTAssertEqual(storeB.recordings.count, 1)
        let firstCompletion = try XCTUnwrap(importer.lastImport)

        await stage(bundle, with: importer)
        let second = try XCTUnwrap(importer.pending)
        guard case .update(let existing) = second.disposition else { return XCTFail("expected update") }
        XCTAssertEqual(existing.id, original.id)
        await importer.confirm()
        XCTAssertEqual(storeB.recordings.count, 1)

        // Same recording id, but a NEW completion — so the window's
        // `onChange` fires and re-selects the recording on a re-import too.
        let secondCompletion = try XCTUnwrap(importer.lastImport)
        XCTAssertEqual(secondCompletion.recordingID, original.id)
        XCTAssertNotEqual(secondCompletion, firstCompletion)
    }

    /// Cancelling while the audio is being copied must leave the library,
    /// the recordings folder and the voice profiles untouched: `confirm()`
    /// holds a value copy of the pending import across that `await`, so it
    /// has to re-check that the import is still the one on screen.
    func test_cancel_during_the_audio_copy_imports_nothing() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let bundle = try await export(original, from: storeA)
        let importer = makeImporter()
        await stage(bundle, with: importer)
        XCTAssertNotNil(importer.pending)

        // Start the import, then cancel before the copy can resume on the
        // main actor. `confirm()`'s first suspension is the detached copy,
        // so the cancel below runs while it is in flight.
        let importTask = Task { @MainActor in await importer.confirm() }
        importer.cancel()
        await importTask.value

        XCTAssertNil(importer.pending)
        XCTAssertNil(importer.lastImport)
        XCTAssertFalse(importer.isImporting)
        XCTAssertTrue(storeB.recordings.isEmpty, "the dismissed import must not reach the library")
        XCTAssertEqual(recordingsDirectoryNames(storeB), [], "no audio, no .partial left behind")
    }

    func test_update_takes_the_bundle_content_but_keeps_the_local_folder_and_removes_old_files() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let importer = makeImporter()
        await stage(try await export(original, from: storeA), with: importer)
        await importer.confirm()
        let first = try XCTUnwrap(storeB.recordings.first)
        XCTAssertNotNil(storeB.createFolder("Clients"))
        storeB.assign(first, toFolder: "Clients")

        // The sender renames a speaker and the title, then shares again.
        storeA.rename(original, to: "Weekly sync (final)")
        storeA.setSpeakerName("Grace", forSpeaker: "SPEAKER_01", recordingID: original.id)
        let updated = try XCTUnwrap(storeA.recordings.first { $0.id == original.id })
        await stage(try await export(updated, from: storeA), with: importer)
        await importer.confirm()

        XCTAssertEqual(storeB.recordings.count, 1)
        let after = try XCTUnwrap(storeB.recordings.first)
        XCTAssertEqual(after.title, "Weekly sync (final)")
        XCTAssertEqual(after.speakerNames["SPEAKER_01"], "Grace")
        XCTAssertEqual(after.folder, "Clients", "the receiver's filing wins")
        XCTAssertNotEqual(after.audioFileName, first.audioFileName)

        let names = recordingsDirectoryNames(storeB)
        XCTAssertFalse(names.contains(first.audioFileName), "old audio removed")
        XCTAssertFalse(names.contains(first.transcriptFileName), "old .txt removed")
        XCTAssertFalse(names.contains(first.subtitleFileName), "old .srt removed")
        XCTAssertTrue(names.contains(after.audioFileName))
        XCTAssertTrue(names.contains(after.transcriptFileName))
    }

    func test_importing_over_a_trashed_copy_restores_it() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let bundle = try await export(original, from: storeA)
        let importer = makeImporter()
        await stage(bundle, with: importer)
        await importer.confirm()
        storeB.softDelete(try XCTUnwrap(storeB.recordings.first))
        XCTAssertTrue(storeB.recordings.first!.isTrashed)

        await stage(bundle, with: importer)
        XCTAssertTrue(importer.pending?.existingIsTrashed == true)
        await importer.confirm()
        XCTAssertFalse(try XCTUnwrap(storeB.recordings.first).isTrashed)
    }

    func test_a_busy_recording_is_not_replaced() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let bundle = try await export(original, from: storeA)
        let importer = makeImporter(busy: { $0 == original.id })
        await stage(bundle, with: importer)   // nothing in B yet → fine
        await importer.confirm()
        let before = try XCTUnwrap(storeB.recordings.first)

        await stage(bundle, with: importer)
        XCTAssertNil(importer.pending)
        XCTAssertEqual(importer.errorMessage, RecordingShareImporter.ImportError.recordingBusy.errorDescription)
        XCTAssertEqual(storeB.recordings.first, before)
    }

    // MARK: - Hostile and damaged bundles

    func test_a_hostile_audio_entry_name_is_rejected_and_nothing_is_written() async throws {
        let dir = scratch.appendingPathComponent("hostile", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try hostileManifestJSON(audioFileName: "../../evil.wav")
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try Data(count: 44).write(to: dir.appendingPathComponent("audio.wav"))
        let importer = makeImporter()
        await stage(try await zipDirectory(dir), with: importer)

        XCTAssertNil(importer.pending)
        XCTAssertTrue(importer.errorMessage?.contains("valid Mila shared recording") == true,
                      importer.errorMessage ?? "nil")
        XCTAssertTrue(storeB.recordings.isEmpty)
        XCTAssertEqual(recordingsDirectoryNames(storeB), [])
    }

    func test_a_symlinked_audio_entry_is_rejected() async throws {
        let dir = scratch.appendingPathComponent("symlinked", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outside = scratch.appendingPathComponent("outside.wav")
        try TestSupport.writeSineWav(at: outside, durationSeconds: 0.1)
        let size = Int64(try outside.resourceValues(forKeys: [.fileSizeKey]).fileSize!)
        try hostileManifestJSON(audioFileName: "audio.wav", byteCount: size,
                                sha: try FileDigest.sha256Hex(of: outside))
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("audio.wav"),
                                                   withDestinationURL: outside)
        // `zip -y` stores the link as a link (ditto would too, but be explicit).
        let archive = scratch.appendingPathComponent("symlinked.milashare")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-q", "-y", "-r", archive.path, "manifest.json", "audio.wav"]
        zip.standardOutput = FileHandle.nullDevice
        zip.standardError = FileHandle.nullDevice
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        let importer = makeImporter()
        await stage(archive, with: importer)
        XCTAssertNil(importer.pending)
        XCTAssertNotNil(importer.errorMessage)
        XCTAssertTrue(storeB.recordings.isEmpty)
    }

    func test_a_tampered_audio_entry_fails_the_integrity_check() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let bundle = try await export(original, from: storeA)
        let dir = scratch.appendingPathComponent("tamper", isDirectory: true)
        try await ZipArchiver.unzip(bundle, into: dir)
        let audio = dir.appendingPathComponent("audio.wav")
        var bytes = try Data(contentsOf: audio)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: audio)

        let importer = makeImporter()
        await stage(try await zipDirectory(dir), with: importer)
        XCTAssertNil(importer.pending)
        XCTAssertTrue(importer.errorMessage?.contains("damaged") == true, importer.errorMessage ?? "nil")
        XCTAssertTrue(storeB.recordings.isEmpty)
        XCTAssertEqual(recordingsDirectoryNames(storeB), [])
    }

    func test_a_size_mismatch_fails_the_integrity_check() async throws {
        let dir = scratch.appendingPathComponent("short", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try hostileManifestJSON(audioFileName: "audio.wav", byteCount: 999)
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try Data(count: 44).write(to: dir.appendingPathComponent("audio.wav"))
        let importer = makeImporter()
        await stage(try await zipDirectory(dir), with: importer)
        XCTAssertNil(importer.pending)
        XCTAssertTrue(importer.errorMessage?.contains("damaged") == true, importer.errorMessage ?? "nil")
    }

    func test_a_future_version_asks_for_a_newer_mila() async throws {
        let dir = scratch.appendingPathComponent("future", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try hostileManifestJSON(audioFileName: "audio.wav", version: 99)
            .write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try Data(count: 44).write(to: dir.appendingPathComponent("audio.wav"))
        let importer = makeImporter()
        await stage(try await zipDirectory(dir), with: importer)
        XCTAssertNil(importer.pending)
        XCTAssertTrue(importer.errorMessage?.contains("newer version of Mila") == true,
                      importer.errorMessage ?? "nil")
    }

    func test_random_bytes_and_a_zip_without_a_manifest_are_refused() async throws {
        let garbage = scratch.appendingPathComponent("garbage.milashare")
        try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: garbage)
        let importer = makeImporter()
        await stage(garbage, with: importer)
        XCTAssertNil(importer.pending)
        XCTAssertNotNil(importer.errorMessage)
        importer.errorMessage = nil

        let dir = scratch.appendingPathComponent("nomanifest", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 44).write(to: dir.appendingPathComponent("audio.wav"))
        await stage(try await zipDirectory(dir), with: importer)
        XCTAssertNil(importer.pending)
        XCTAssertTrue(importer.errorMessage?.contains("valid Mila shared recording") == true,
                      importer.errorMessage ?? "nil")
        XCTAssertTrue(storeB.recordings.isEmpty)
    }

    // MARK: - Storage cap, cancel, queue

    func test_storage_cap_blocks_the_import_before_any_audio_is_copied() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let bundle = try await export(original, from: storeA)
        let importer = makeImporter(storage: makeStorageSettings(limitBytes: 1))
        await stage(bundle, with: importer)
        let pending = try XCTUnwrap(importer.pending)
        XCTAssertTrue(pending.wouldExceedStorageCap)

        await importer.confirm()
        XCTAssertNotNil(importer.pending, "the sheet stays up so the user can cancel")
        XCTAssertTrue(importer.errorMessage?.contains("Storage limit") == true, importer.errorMessage ?? "nil")
        XCTAssertTrue(storeB.recordings.isEmpty)
        XCTAssertEqual(recordingsDirectoryNames(storeB), [])
        importer.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.stagingDirectory.path))
    }

    func test_cancel_removes_the_staging_directory_and_two_opens_stage_in_turn() async throws {
        let one = try makeCompletedRecording(in: storeA, title: "One")
        let two = try makeCompletedRecording(in: storeA, title: "Two")
        let bundleOne = try await export(one, from: storeA)
        let bundleTwo = try await export(two, from: storeA)
        let importer = makeImporter()

        importer.handleOpen(bundleOne)
        importer.handleOpen(bundleTwo)
        for _ in 0..<400 where importer.pending == nil { try? await Task.sleep(nanoseconds: 25_000_000) }
        let first = try XCTUnwrap(importer.pending)
        XCTAssertEqual(first.manifest.recording.title, "One")

        importer.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.stagingDirectory.path))
        for _ in 0..<400 where importer.pending == nil { try? await Task.sleep(nanoseconds: 25_000_000) }
        let second = try XCTUnwrap(importer.pending)
        XCTAssertEqual(second.manifest.recording.title, "Two")
        importer.cancel()
        XCTAssertTrue(storeB.recordings.isEmpty)
    }

    func test_stray_partial_files_are_swept_at_init() throws {
        let stray = storeB.recordingsDirectory.appendingPathComponent("crashed import.wav.partial")
        try Data(count: 10_000).write(to: stray)
        _ = makeImporter()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
    }

    // MARK: - Voice profiles

    private func vector(_ head: [Float]) -> [Float] {
        head + [Float](repeating: 0, count: SpeakerEmbeddingModel.current.dimension - head.count)
    }

    func test_shared_voice_profiles_are_applied_and_labels_follow_the_chosen_targets() async throws {
        let original = try makeCompletedRecording(in: storeA,
                                                  speakerNames: ["SPEAKER_00": "Daniel", "SPEAKER_01": "Ada"])
        let shared = [
            SharedSpeakerProfile(name: "Daniel", embedding: vector([1, 0]), sampleCount: 4,
                                 embeddingModel: SpeakerEmbeddingModel.current.id),
            SharedSpeakerProfile(name: "Ada", embedding: vector([0, 1]), sampleCount: 2,
                                 embeddingModel: SpeakerEmbeddingModel.current.id),
        ]
        let bundle = try await export(original, from: storeA, profiles: shared)

        // B already knows Daniel as "Dan" (same voice) and has nobody like Ada.
        let voice = makeVoiceSettings(enabled: true)
        let profiles = SpeakerProfileStore(directory: rootB, settings: voice)
        profiles.updateProfile(name: "Dan", embedding: vector([0.99, 0.01]), sampleCount: 2)
        let importer = makeImporter(profiles: profiles, voice: voice)

        await stage(bundle, with: importer)
        let pending = try XCTUnwrap(importer.pending)
        XCTAssertEqual(pending.speakerPlan.rows.map(\.id), ["Ada", "Daniel"])
        let daniel = try XCTUnwrap(pending.speakerPlan.rows.first { $0.id == "Daniel" })
        let dan = try XCTUnwrap(profiles.profile(named: "Dan"))
        XCTAssertEqual(daniel.target, .merge(into: dan.id), "voice match beats the name difference")
        let ada = try XCTUnwrap(pending.speakerPlan.rows.first { $0.id == "Ada" })
        XCTAssertEqual(ada.target, .addAsNew(name: "Ada"))
        XCTAssertEqual(ada.candidates.map(\.profile.name), ["Dan"],
                       "an unmatched speaker still offers every local profile")

        await importer.confirm()
        XCTAssertNil(importer.errorMessage)
        let imported = try XCTUnwrap(storeB.recordings.first)
        XCTAssertEqual(imported.speakerNames, ["SPEAKER_00": "Dan", "SPEAKER_01": "Ada"],
                       "labels are rewritten to the receiver's chosen names")

        let mergedDan = try XCTUnwrap(profiles.profile(named: "Dan"))
        XCTAssertEqual(mergedDan.sampleCount, 6)
        XCTAssertEqual(mergedDan.importedShares.count, 1)
        XCTAssertEqual(mergedDan.importedShares.first?.sharedName, "Daniel")
        let newAda = try XCTUnwrap(profiles.profile(named: "Ada"))
        XCTAssertEqual(newAda.sampleCount, 2)
        XCTAssertEqual(newAda.embeddingModel, SpeakerEmbeddingModel.current.id)

        // Second import of the same bundle: both rows default to skip.
        await stage(bundle, with: importer)
        let again = try XCTUnwrap(importer.pending)
        XCTAssertTrue(again.speakerPlan.rows.allSatisfy { $0.alreadyImported && $0.target == .skip })
        XCTAssertTrue(again.speakerPlan.rows.allSatisfy { !$0.isBlocked }, "but the menu stays enabled")
        await importer.confirm()
        XCTAssertEqual(try XCTUnwrap(profiles.profile(named: "Dan")).sampleCount, 6, "no double count")
    }

    func test_with_voice_recognition_off_profiles_are_blocked_but_the_recording_imports() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let shared = [SharedSpeakerProfile(name: "Daniel", embedding: vector([1, 0]), sampleCount: 4,
                                           embeddingModel: SpeakerEmbeddingModel.current.id)]
        let bundle = try await export(original, from: storeA, profiles: shared)
        let voice = makeVoiceSettings(enabled: false)
        let profiles = SpeakerProfileStore(directory: rootB, settings: voice)
        let importer = makeImporter(profiles: profiles, voice: voice)

        await stage(bundle, with: importer)
        let pending = try XCTUnwrap(importer.pending)
        XCTAssertEqual(pending.speakerPlan.rows.first?.blocker, .voiceRecognitionOff)
        await importer.confirm()
        XCTAssertEqual(storeB.recordings.count, 1)
        XCTAssertTrue(profiles.profiles.isEmpty)
        XCTAssertFalse(profiles.hasStoredProfilesOnDisk, "nothing written behind an opted-out user")
        XCTAssertFalse(voice.isEnabled, "import never flips the toggle")
    }
}
