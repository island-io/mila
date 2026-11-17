import Combine
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
                              busy: @escaping (UUID) -> Bool = { _ in false },
                              copyAudio: @escaping RecordingShareImporter.AudioCopier = {
                                  try await RecordingShareImporter.copyFile($0, to: $1)
                              }) -> RecordingShareImporter {
        RecordingShareImporter(store: storeB, storageSettings: storage, profileStore: profiles,
                               voiceRecognition: voice, similarityThreshold: { threshold },
                               speakerDirectory: SpeakerDirectory(directory: rootB),
                               isRecordingBusy: busy,
                               // Keep the audio filename stable for the assertions below.
                               compressImportedWAV: false,
                               copyAudio: copyAudio)
    }

    /// A one-shot latch for sequencing an async test: `wait()` suspends
    /// until `open()`, and stays open.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var opened: Bool { isOpen }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
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

    /// Overwrite what the central directory DECLARES as `entryName`'s
    /// uncompressed size. The local header and the data are untouched, so
    /// the archive still extracts — this fakes exactly the one thing a
    /// hostile archive can lie about to the pre-extraction check.
    private func patchDeclaredSize(in archive: URL, entry entryName: String, to size: UInt32,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        var bytes = try Data(contentsOf: archive)
        let signature: [UInt8] = [0x50, 0x4b, 0x01, 0x02]
        let name = Array(entryName.utf8)
        var patched = false
        var i = 0
        while i + 46 <= bytes.count {
            if Array(bytes[i..<i + 4]) == signature {
                let nameLength = Int(bytes[i + 28]) | Int(bytes[i + 29]) << 8
                if i + 46 + nameLength <= bytes.count, Array(bytes[i + 46..<i + 46 + nameLength]) == name {
                    for (k, shift) in [24, 25, 26, 27].enumerated() {
                        bytes[i + shift] = UInt8(truncatingIfNeeded: size >> (8 * UInt32(k)))
                    }
                    patched = true
                    break
                }
            }
            i += 1
        }
        XCTAssertTrue(patched, "no central directory header for \(entryName)", file: file, line: line)
        try bytes.write(to: archive)
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
    ///
    /// The copy is held open through the importer's copy seam. Without it
    /// there is no moment at which Cancel provably arrives mid-copy: a
    /// `Task { confirm() }` followed by `cancel()` on the same main-actor
    /// turn cancels BEFORE `confirm()` has run a line, so it returns at its
    /// first guard and the re-check after the `await` is never exercised.
    func test_cancel_during_the_audio_copy_imports_nothing() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let bundle = try await export(original, from: storeA)
        // Copy for real, then park: Cancel arrives with the `.partial` already
        // on disk and the import suspended, which is the worst moment.
        let copied = Gate()
        let release = Gate()
        let importer = makeImporter(copyAudio: { source, destination in
            try await RecordingShareImporter.copyFile(source, to: destination)
            await copied.open()
            await release.wait()
        })
        await stage(bundle, with: importer)
        XCTAssertNotNil(importer.pending)

        let importTask = Task { @MainActor in await importer.confirm() }
        for _ in 0..<400 {
            if await copied.opened { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let reachedTheCopy = await copied.opened
        XCTAssertTrue(reachedTheCopy, "confirm() never reached the audio copy")
        XCTAssertTrue(importer.isImporting, "the slot is held while the copy is in flight")
        XCTAssertTrue(recordingsDirectoryNames(storeB).contains { $0.hasSuffix(".partial") },
                      "the copy is on disk when Cancel arrives — that is the case under test")

        importer.cancel()
        XCTAssertFalse(importer.isImporting,
                       "cancel releases the import slot at once — a queued sheet must not inherit a disabled button")
        await release.open()
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

    func test_confirm_resolves_the_existing_copy_against_the_live_store() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let bundle = try await export(original, from: storeA)
        let importer = makeImporter()
        await stage(bundle, with: importer)
        await importer.confirm()
        let first = try XCTUnwrap(storeB.recordings.first)
        XCTAssertNotNil(storeB.createFolder("Clients"))
        storeB.assign(first, toFolder: "Clients")

        // The sheet says "replace" — then the user deletes their copy for
        // good while it is up. The import must add rather than replace a
        // row that is no longer there, and must not inherit the deleted
        // copy's filing.
        await stage(bundle, with: importer)
        let pending = try XCTUnwrap(importer.pending)
        XCTAssertTrue(pending.isUpdate)
        storeB.permanentlyDelete(try XCTUnwrap(storeB.recordings.first))
        XCTAssertTrue(storeB.recordings.isEmpty)

        await importer.confirm()
        XCTAssertNil(importer.errorMessage)
        XCTAssertNil(importer.refusalMessage)
        XCTAssertEqual(storeB.recordings.count, 1)
        let imported = try XCTUnwrap(storeB.recordings.first)
        XCTAssertEqual(imported.id, original.id)
        XCTAssertNil(imported.folder, "the deleted copy's filing is not resurrected")
        XCTAssertTrue(recordingsDirectoryNames(storeB).contains(imported.audioFileName))
    }

    /// The audio copy is an `await`, and the store can move under it, so
    /// `confirm()` resolves the local copy against the store again once the
    /// copy is done: here the user deletes their copy for good while the
    /// audio is copying, and the import must add rather than inherit the
    /// deleted copy's filing.
    func test_existing_copy_is_resolved_again_after_the_audio_copy() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let bundle = try await export(original, from: storeA)
        let plain = makeImporter()
        await stage(bundle, with: plain)
        await plain.confirm()
        let first = try XCTUnwrap(storeB.recordings.first)
        XCTAssertNotNil(storeB.createFolder("Clients"))
        storeB.assign(first, toFolder: "Clients")

        let copied = Gate()
        let release = Gate()
        let importer = makeImporter(copyAudio: { source, destination in
            try await RecordingShareImporter.copyFile(source, to: destination)
            await copied.open()
            await release.wait()
        })
        await stage(bundle, with: importer)
        XCTAssertTrue(try XCTUnwrap(importer.pending).isUpdate, "the sheet says replace")

        let importTask = Task { @MainActor in await importer.confirm() }
        for _ in 0..<400 {
            if await copied.opened { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let reachedTheCopy = await copied.opened
        XCTAssertTrue(reachedTheCopy, "confirm() never reached the audio copy")
        storeB.permanentlyDelete(try XCTUnwrap(storeB.recordings.first))
        XCTAssertTrue(storeB.recordings.isEmpty)
        await release.open()
        await importTask.value

        XCTAssertNil(importer.errorMessage)
        XCTAssertNil(importer.refusalMessage)
        XCTAssertEqual(storeB.recordings.count, 1)
        let imported = try XCTUnwrap(storeB.recordings.first)
        XCTAssertEqual(imported.id, original.id)
        XCTAssertNil(imported.folder, "the deleted copy's filing is not resurrected")
        XCTAssertFalse(recordingsDirectoryNames(storeB).contains { $0.hasSuffix(".partial") })
    }

    /// Same window, the case the busy check exists for: transcription of the
    /// local copy starts while the audio is copying. The import must not
    /// replace a recording under an in-flight pass, and must refuse the way
    /// the pre-copy check does — sheet left up, nothing written.
    func test_a_copy_that_becomes_busy_during_the_audio_copy_is_not_replaced() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let bundle = try await export(original, from: storeA)
        let plain = makeImporter()
        await stage(bundle, with: plain)
        await plain.confirm()
        let before = try XCTUnwrap(storeB.recordings.first)

        final class Flag { var isOn = false }
        let busy = Flag()
        let copied = Gate()
        let release = Gate()
        let importer = makeImporter(busy: { _ in busy.isOn }, copyAudio: { source, destination in
            try await RecordingShareImporter.copyFile(source, to: destination)
            await copied.open()
            await release.wait()
        })
        await stage(bundle, with: importer)   // not busy yet, so it stages

        let importTask = Task { @MainActor in await importer.confirm() }
        for _ in 0..<400 {
            if await copied.opened { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let reachedTheCopy = await copied.opened
        XCTAssertTrue(reachedTheCopy, "confirm() never reached the audio copy")
        busy.isOn = true
        await release.open()
        await importTask.value

        XCTAssertNotNil(importer.pending, "the sheet stays up, as after a pre-copy refusal")
        XCTAssertEqual(importer.refusalMessage, RecordingShareImporter.ImportError.recordingBusy.errorDescription)
        XCTAssertNil(importer.errorMessage)
        XCTAssertFalse(importer.isImporting)
        XCTAssertEqual(storeB.recordings.first, before, "nothing replaced")
        XCTAssertFalse(recordingsDirectoryNames(storeB).contains { $0.hasSuffix(".partial") },
                       "no .partial left behind")
        importer.cancel()
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

    // MARK: - Declared contents (checked before extraction)

    /// `ditto -x` inflates everything it finds, so the archive's central
    /// directory is checked first and an archive that is not exactly a
    /// bundle is refused before a byte of it is inflated. The pure check is
    /// pinned here; the tests after it go through `stage`.
    func test_validateEntries_accepts_exactly_the_fixed_names_and_nothing_else() throws {
        func entry(_ name: String, _ size: UInt64 = 10,
                   dir: Bool = false, link: Bool = false) -> ZipArchiver.Entry {
            ZipArchiver.Entry(name: name, uncompressedSize: size, isDirectory: dir, isSymlink: link)
        }
        let full = try RecordingShareImporter.validateEntries(
            [entry("manifest.json"), entry("audio.m4a", 500), entry("transcript.txt")])
        XCTAssertEqual(full, .init(audioEntryName: "audio.m4a", hasTranscript: true,
                                   totalUncompressedBytes: 520,
                                   entryNames: ["manifest.json", "audio.m4a", "transcript.txt"]))
        let minimal = try RecordingShareImporter.validateEntries([entry("audio.wav", 44), entry("manifest.json")])
        XCTAssertEqual(minimal, .init(audioEntryName: "audio.wav", hasTranscript: false,
                                      totalUncompressedBytes: 54,
                                      entryNames: ["manifest.json", "audio.wav"]))

        func rejects(_ entries: [ZipArchiver.Entry], _ fragment: String, line: UInt = #line) {
            XCTAssertThrowsError(try RecordingShareImporter.validateEntries(entries), line: line) { error in
                let message = (error as? ShareManifest.LoadError)?.errorDescription ?? "\(error)"
                XCTAssertTrue(message.contains(fragment), message, line: line)
            }
        }
        rejects([entry("manifest.json"), entry("audio.wav"), entry("notes.txt")], "entry Mila doesn't expect")
        rejects([entry("manifest.json"), entry("audio.wav"), entry("__MACOSX/._manifest.json")],
                "entry Mila doesn't expect")
        rejects([entry("manifest.json"), entry("audio.wav"), entry("extra/", 0, dir: true)], "ordinary file")
        rejects([entry("manifest.json"), entry("audio.wav", link: true)], "ordinary file")
        rejects([entry("manifest.json"), entry("audio.wav"), entry("audio.m4a")], "more than one audio")
        rejects([entry("manifest.json"), entry("manifest.json"), entry("audio.wav")], "same entry twice")
        rejects([entry("audio.wav")], "no manifest")
        rejects([entry("manifest.json")], "no audio")
        rejects([entry("manifest.json", UInt64(RecordingShareImporter.maxManifestBytes) + 1), entry("audio.wav")],
                "manifest is too large")
        rejects([entry("manifest.json"), entry("audio.wav"),
                 entry("transcript.txt", UInt64(RecordingShareImporter.maxTranscriptBytes) + 1)],
                "transcript is too large")
        rejects([entry("manifest.json"), entry("audio.wav", UInt64(RecordingShareImporter.maxUncompressedBytes))],
                "too large to be a Mila shared recording")
        // A sum that overflows is just another way of being too large. Only
        // the audio entry can carry a size that big — the text entries hit
        // their own caps first — so the overflow is the manifest's few
        // bytes on top of an audio entry at `Int64.max` exactly (one past it
        // fails the per-entry bound instead).
        rejects([entry("manifest.json"), entry("audio.wav", .max)], "too large to be a Mila shared recording")
        rejects([entry("manifest.json"), entry("audio.wav", UInt64(Int64.max))],
                "too large to be a Mila shared recording")
    }

    /// The other half of the entry-set check: what `ditto` actually put in
    /// the staging directory must be what the central directory listed.
    /// Exercised on a directory directly — an archive whose local headers
    /// disagree with its central directory is not something `ditto` or
    /// `zip` will write — and wired into `stage` right after the unzip.
    func test_extracted_contents_must_match_the_declared_entry_set_exactly() throws {
        let dir = TestSupport.makeTempRoot(label: "RecordingShareImporterTests.extracted")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let declared = RecordingShareImporter.DeclaredContents(
            audioEntryName: "audio.wav", hasTranscript: true, totalUncompressedBytes: 30,
            entryNames: ["manifest.json", "audio.wav", "transcript.txt"])
        for name in declared.entryNames {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        XCTAssertNoThrow(try RecordingShareImporter.requireExtractedEntries(in: dir, match: declared))

        // An entry the listing never mentioned.
        let smuggled = dir.appendingPathComponent("payload.sh")
        try Data("x".utf8).write(to: smuggled)
        XCTAssertThrowsError(try RecordingShareImporter.requireExtractedEntries(in: dir, match: declared)) { error in
            let message = (error as? ShareManifest.LoadError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("table of contents"), message)
        }
        try FileManager.default.removeItem(at: smuggled)

        // An entry the listing promised and the stream did not deliver.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("transcript.txt"))
        XCTAssertThrowsError(try RecordingShareImporter.requireExtractedEntries(in: dir, match: declared))

        // No staging directory at all is "unreadable", not "malformed".
        XCTAssertThrowsError(try RecordingShareImporter.requireExtractedEntries(
            in: dir.appendingPathComponent("missing"), match: declared)) { error in
            if case .unreadable = error as? ShareManifest.LoadError {} else { XCTFail("\(error)") }
        }
    }

    func test_an_unexpected_extra_entry_is_rejected_before_extraction() async throws {
        // A real bundle with one more file in it, as a tool other than Mila
        // might repack it.
        let original = try makeCompletedRecording(in: storeA)
        let dir = scratch.appendingPathComponent("extra", isDirectory: true)
        try await ZipArchiver.unzip(try await export(original, from: storeA), into: dir)
        try Data("notes".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let importer = makeImporter()
        await stage(try await zipDirectory(dir), with: importer)
        XCTAssertNil(importer.pending)
        XCTAssertTrue(importer.errorMessage?.contains("entry Mila doesn't expect") == true,
                      importer.errorMessage ?? "nil")
        XCTAssertTrue(storeB.recordings.isEmpty)
        XCTAssertEqual(recordingsDirectoryNames(storeB), [])

        // A subfolder is two entries `ditto` would create — the directory
        // and its file — and neither is a bundle's.
        importer.errorMessage = nil
        try FileManager.default.removeItem(at: dir.appendingPathComponent("notes.txt"))
        let sub = dir.appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("x.txt"))
        await stage(try await zipDirectory(dir), with: importer)
        XCTAssertNil(importer.pending)
        XCTAssertTrue(importer.errorMessage?.contains("valid Mila shared recording") == true,
                      importer.errorMessage ?? "nil")
        XCTAssertTrue(storeB.recordings.isEmpty)
    }

    func test_a_declared_size_over_the_cap_is_rejected_without_extracting() async throws {
        // A real, small bundle whose central directory has been edited to
        // claim the audio inflates to 4 GB. Extracted, it would have imported
        // — so a "too large" verdict can only have come from the listing.
        let original = try makeCompletedRecording(in: storeA)
        let bundle = try await export(original, from: storeA)
        try patchDeclaredSize(in: bundle, entry: "audio.wav", to: 0xFFFF_FFFE)
        let importer = makeImporter()
        await stage(bundle, with: importer)
        XCTAssertNil(importer.pending)
        XCTAssertTrue(importer.errorMessage?.contains("too large to be a Mila shared recording") == true,
                      importer.errorMessage ?? "nil")
        XCTAssertTrue(storeB.recordings.isEmpty)
        XCTAssertEqual(recordingsDirectoryNames(storeB), [])
    }

    func test_an_oversized_manifest_is_rejected() async throws {
        // Honest: the directory declares the real size, and the listing
        // refuses it before extraction.
        let dir = scratch.appendingPathComponent("bigmanifest", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: Int(RecordingShareImporter.maxManifestBytes) + 1)
            .write(to: dir.appendingPathComponent("manifest.json"))
        try Data(count: 44).write(to: dir.appendingPathComponent("audio.wav"))
        let importer = makeImporter()
        await stage(try await zipDirectory(dir), with: importer)
        XCTAssertNil(importer.pending)
        XCTAssertTrue(importer.errorMessage?.contains("manifest is too large") == true,
                      importer.errorMessage ?? "nil")

        // Lying: the same archive, its directory edited to declare a tiny
        // manifest. The listing passes, and `ditto` inflates the whole
        // stream regardless of what the directory said — so the extracted
        // file's real size is checked again before it is read, and fails.
        importer.errorMessage = nil
        let lying = try await zipDirectory(dir)
        try patchDeclaredSize(in: lying, entry: "manifest.json", to: 10)
        await stage(lying, with: importer)
        XCTAssertNil(importer.pending)
        XCTAssertTrue(importer.errorMessage?.contains("manifest is too large") == true,
                      importer.errorMessage ?? "nil")
        XCTAssertTrue(storeB.recordings.isEmpty)
        XCTAssertEqual(recordingsDirectoryNames(storeB), [])
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
        XCTAssertTrue(importer.refusalMessage?.contains("Storage limit") == true, importer.refusalMessage ?? "nil")
        XCTAssertNil(importer.errorMessage, "the refusal is the sheet's to show; no alert queues behind it")
        XCTAssertTrue(storeB.recordings.isEmpty)
        XCTAssertEqual(recordingsDirectoryNames(storeB), [])
        importer.cancel()
        XCTAssertNil(importer.refusalMessage, "the refusal goes with the sheet it was shown in")
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
        XCTAssertNil(importer.errorMessage)
        XCTAssertEqual(try XCTUnwrap(profiles.profile(named: "Dan")).sampleCount, 6, "no double count")
        XCTAssertEqual(try XCTUnwrap(storeB.recordings.first).speakerNames,
                       ["SPEAKER_00": "Dan", "SPEAKER_01": "Ada"],
                       "a re-import keeps the labels the first import chose, not the sender's")
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

    /// `recordings.json` is the commit point for the whole import, and the
    /// voice profiles are written BEFORE it — folded, created and tagged
    /// with this bundle's tokens — because the row's labels come out of that
    /// step. When the row cannot be saved they have to go back exactly, or
    /// the user keeps voice data from a recording they do not have and the
    /// retry greets them with "Already imported from this file" (#319).
    func test_a_failed_library_write_puts_the_voice_profiles_back_and_the_retry_imports_them() async throws {
        let original = try makeCompletedRecording(in: storeA,
                                                  speakerNames: ["SPEAKER_00": "Daniel", "SPEAKER_01": "Ada"])
        let shared = [
            SharedSpeakerProfile(name: "Daniel", embedding: vector([1, 0]), sampleCount: 4,
                                 embeddingModel: SpeakerEmbeddingModel.current.id),
            SharedSpeakerProfile(name: "Ada", embedding: vector([0, 1]), sampleCount: 2,
                                 embeddingModel: SpeakerEmbeddingModel.current.id),
        ]
        let bundle = try await export(original, from: storeA, profiles: shared)

        let voice = makeVoiceSettings(enabled: true)
        let profiles = SpeakerProfileStore(directory: rootB, settings: voice)
        profiles.updateProfile(name: "Dan", embedding: vector([0.99, 0.01]), sampleCount: 2)
        let dan = try XCTUnwrap(profiles.profile(named: "Dan"))
        let profilesURL = rootB.appendingPathComponent("speaker-profiles.json")
        let bytesBefore = try Data(contentsOf: profilesURL)
        let importer = makeImporter(profiles: profiles, voice: voice)

        // Make recordings.json a directory so the atomic write cannot
        // succeed — the seam `RecordingStoreUpsertTests` uses.
        try? FileManager.default.removeItem(at: storeB.storeURL)
        try FileManager.default.createDirectory(at: storeB.storeURL, withIntermediateDirectories: true)
        let audioFilesBefore = recordingsDirectoryNames(storeB)

        await stage(bundle, with: importer)
        let pending = try XCTUnwrap(importer.pending)
        XCTAssertEqual(pending.speakerPlan.rows.map(\.target), [.addAsNew(name: "Ada"), .merge(into: dan.id)],
                       "the plan would change the profiles")
        await importer.confirm()

        XCTAssertEqual(importer.errorMessage, RecordingShareImporter.ImportError.saveFailed.errorDescription)
        XCTAssertNil(importer.pending)
        XCTAssertTrue(storeB.recordings.isEmpty)
        XCTAssertEqual(recordingsDirectoryNames(storeB), audioFilesBefore, "the copied audio is gone")
        XCTAssertEqual(profiles.profiles.map(\.name), ["Dan"], "no profile added")
        XCTAssertEqual(try XCTUnwrap(profiles.profile(named: "Dan")).sampleCount, 2, "nothing folded")
        XCTAssertTrue(profiles.importedShareTokens.isEmpty, "no token, so the retry is a first import")
        XCTAssertEqual(try Data(contentsOf: profilesURL), bytesBefore, "speaker-profiles.json is byte-identical")

        // The library is writable again: the retry is a first import, and
        // brings the recording AND its voice data.
        try FileManager.default.removeItem(at: storeB.storeURL)
        importer.errorMessage = nil
        await stage(bundle, with: importer)
        let retry = try XCTUnwrap(importer.pending)
        XCTAssertTrue(retry.speakerPlan.rows.allSatisfy { !$0.alreadyImported })
        XCTAssertEqual(retry.speakerPlan.rows.map(\.target), [.addAsNew(name: "Ada"), .merge(into: dan.id)])
        await importer.confirm()
        XCTAssertNil(importer.errorMessage)
        XCTAssertEqual(try XCTUnwrap(storeB.recordings.first).speakerNames,
                       ["SPEAKER_00": "Dan", "SPEAKER_01": "Ada"])
        XCTAssertEqual(try XCTUnwrap(profiles.profile(named: "Dan")).sampleCount, 6)
        XCTAssertEqual(try XCTUnwrap(profiles.profile(named: "Ada")).sampleCount, 2)
        XCTAssertEqual(profiles.importedShareTokens.count, 2)
    }

    /// The no-file case of the same rollback. A receiver who had never
    /// stored a voice profile must not end up with a `speaker-profiles.json`
    /// holding `[]`: Settings reads the file's existence as "voice profiles
    /// from an earlier opt-in are still stored" and offers to delete them.
    func test_a_failed_library_write_leaves_no_speaker_profiles_file_behind() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let shared = [SharedSpeakerProfile(name: "Daniel", embedding: vector([1, 0]), sampleCount: 4,
                                           embeddingModel: SpeakerEmbeddingModel.current.id)]
        let bundle = try await export(original, from: storeA, profiles: shared)
        let voice = makeVoiceSettings(enabled: true)
        let profiles = SpeakerProfileStore(directory: rootB, settings: voice)
        let profilesURL = rootB.appendingPathComponent("speaker-profiles.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: profilesURL.path))
        let importer = makeImporter(profiles: profiles, voice: voice)
        try? FileManager.default.removeItem(at: storeB.storeURL)
        try FileManager.default.createDirectory(at: storeB.storeURL, withIntermediateDirectories: true)

        await stage(bundle, with: importer)
        XCTAssertEqual(try XCTUnwrap(importer.pending).speakerPlan.rows.map(\.target),
                       [.addAsNew(name: "Daniel")])
        await importer.confirm()

        XCTAssertEqual(importer.errorMessage, RecordingShareImporter.ImportError.saveFailed.errorDescription)
        XCTAssertTrue(storeB.recordings.isEmpty)
        XCTAssertTrue(profiles.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profilesURL.path))
        XCTAssertFalse(profiles.hasStoredProfilesOnDisk)
    }

    /// The crash window #324's rollback could not close: if Mila dies
    /// between the voice-profile write and the `recordings.json` write, the
    /// profiles are merged and the bundle's tokens recorded for a recording
    /// that is not in the library, and the retry skips every speaker as
    /// "already imported". So `speaker-profiles.json` must still be as it
    /// was at the moment the store takes the row (#329). Observed through
    /// `recordings`, which `upsertImported` publishes before it writes.
    func test_voice_profiles_reach_disk_only_after_the_recording_row() async throws {
        let original = try makeCompletedRecording(in: storeA,
                                                  speakerNames: ["SPEAKER_00": "Daniel", "SPEAKER_01": "Ada"])
        let shared = [
            SharedSpeakerProfile(name: "Daniel", embedding: vector([1, 0]), sampleCount: 4,
                                 embeddingModel: SpeakerEmbeddingModel.current.id),
            SharedSpeakerProfile(name: "Ada", embedding: vector([0, 1]), sampleCount: 2,
                                 embeddingModel: SpeakerEmbeddingModel.current.id),
        ]
        let bundle = try await export(original, from: storeA, profiles: shared)
        let voice = makeVoiceSettings(enabled: true)
        let profiles = SpeakerProfileStore(directory: rootB, settings: voice)
        profiles.updateProfile(name: "Dan", embedding: vector([0.99, 0.01]), sampleCount: 2)
        let profilesURL = rootB.appendingPathComponent("speaker-profiles.json")
        let bytesBefore = try Data(contentsOf: profilesURL)
        let importer = makeImporter(profiles: profiles, voice: voice)

        var bytesWhenTheRowArrived: Data?
        let watch = storeB.$recordings.dropFirst().sink { rows in
            if !rows.isEmpty, bytesWhenTheRowArrived == nil {
                bytesWhenTheRowArrived = try? Data(contentsOf: profilesURL)
            }
        }
        defer { watch.cancel() }

        await stage(bundle, with: importer)
        await importer.confirm()

        XCTAssertNil(importer.errorMessage)
        XCTAssertEqual(bytesWhenTheRowArrived, bytesBefore,
                       "speaker-profiles.json untouched until the row is committed")
        // ...and committed after it.
        let reloaded = SpeakerProfileStore(directory: rootB, settings: voice)
        XCTAssertEqual(reloaded.profile(named: "Dan")?.sampleCount, 6)
        XCTAssertEqual(reloaded.profile(named: "Ada")?.sampleCount, 2)
        XCTAssertEqual(reloaded.importedShareTokens.count, 2)
    }

    /// An import into a library whose `speaker-profiles.json` failed to
    /// parse at launch must not overwrite it: the damaged file is moved
    /// aside intact and the imported voices go to a fresh file (#329).
    func test_an_import_moves_a_damaged_profiles_file_aside_instead_of_overwriting_it() async throws {
        let original = try makeCompletedRecording(in: storeA)
        let shared = [SharedSpeakerProfile(name: "Daniel", embedding: vector([1, 0]), sampleCount: 4,
                                           embeddingModel: SpeakerEmbeddingModel.current.id)]
        let bundle = try await export(original, from: storeA, profiles: shared)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let profilesURL = rootB.appendingPathComponent("speaker-profiles.json")
        let damaged = Data("[{\"name\": \"Dan\", \"embedding\": [0.9".utf8)
        try damaged.write(to: profilesURL)
        let voice = makeVoiceSettings(enabled: true)
        let profiles = SpeakerProfileStore(directory: rootB, settings: voice)
        XCTAssertTrue(profiles.loadedFromDamagedFile, "precondition")
        let importer = makeImporter(profiles: profiles, voice: voice)

        await stage(bundle, with: importer)
        await importer.confirm()

        XCTAssertNil(importer.errorMessage)
        XCTAssertEqual(storeB.recordings.count, 1)
        let aside = try FileManager.default.contentsOfDirectory(atPath: rootB.path)
            .filter { $0.hasPrefix("speaker-profiles.damaged-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try Data(contentsOf: rootB.appendingPathComponent(aside[0])), damaged)
        XCTAssertEqual(SpeakerProfileStore(directory: rootB, settings: voice).profiles.map(\.name), ["Daniel"])
    }
}
