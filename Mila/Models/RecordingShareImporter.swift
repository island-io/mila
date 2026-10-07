import AppKit
import Combine
import Foundation
import MilaKit
import os
import UniformTypeIdentifiers

/// Opens a `.milashare` bundle, verifies it, previews what importing would
/// do — add a recording or replace the copy already here, and what happens
/// to each shared voice profile — and, once the user confirms, writes it
/// into the library. Mirrors `MilaConfigImporter`: `handleOpen(_:)` from the
/// file-open handler, a `PendingImport` that drives a `.sheet(item:)`, and
/// `confirm()` / `cancel()` from the sheet's buttons.
///
/// ## Trust boundary
///
/// A bundle is a zip somebody sent. The importer extracts it into a
/// throwaway directory and reads exactly three fixed entry names
/// (`ShareManifest`), checks each is a regular file inside that directory,
/// and verifies the audio's size and SHA-256 against the manifest. The
/// library filename is minted here from the title — nothing in the archive
/// names a file on this Mac.
///
/// ## Crash safety
///
/// Audio is copied to `<dest>.partial` first and renamed in the same
/// main-actor turn as the store write, so a crash mid-copy leaves an inert
/// file rather than a `.wav` that `RecordingStore.recoverOrphanRecordings`
/// would resurrect as a phantom "Recovered recording" on next launch. Stray
/// `.partial` files are swept at init.
@MainActor
final class RecordingShareImporter: ObservableObject {

    enum Disposition: Equatable {
        case add
        case update(existing: Recording)
    }

    enum ImportError: LocalizedError, Equatable {
        case recordingBusy
        case storageCap(String)
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .recordingBusy:
                return "Your copy of this recording is being transcribed right now. Try again when it finishes."
            case .storageCap(let detail):
                return detail
            case .saveFailed:
                return "Couldn't save the imported recording to your library."
            }
        }
    }

    struct PendingImport: Identifiable {
        let id = UUID()
        let manifest: ShareManifest
        let stagingDirectory: URL
        let audioURL: URL
        let transcriptText: String
        /// The bundle's filename — user content, logged `.private`.
        let sourceName: String
        let bundleByteCount: Int64
        let disposition: Disposition
        /// Preview only; `confirm()` re-checks against the live store.
        let wouldExceedStorageCap: Bool
        /// What will happen to each shared voice profile. Edited in place
        /// by the sheet. Empty when the bundle carries none.
        var speakerPlan: SpeakerProfileImportPlan

        var isUpdate: Bool {
            if case .update = disposition { return true }
            return false
        }
        var existingIsTrashed: Bool {
            if case .update(let existing) = disposition { return existing.isTrashed }
            return false
        }
    }

    /// Non-nil while the confirmation sheet should be shown.
    @Published var pending: PendingImport?
    /// Non-nil to surface a load / verify / save error to the user.
    @Published var errorMessage: String?
    /// True while a bundle is being extracted and hashed.
    @Published private(set) var isStaging = false
    /// True from the Import click until the library write finished or was
    /// abandoned. The sheet disables its button on it, and `confirm()`
    /// refuses to start twice — a second click during the audio copy would
    /// otherwise fold the same voice profiles in twice.
    @Published private(set) var isImporting = false

    /// A completed import, for the window to select the recording. Carries
    /// a fresh `token` so re-importing the SAME recording (the replace /
    /// restore path, same UUID) still reads as a change to `onChange`.
    struct Completion: Equatable {
        let recordingID: UUID
        let token = UUID()
    }
    @Published private(set) var lastImport: Completion?

    /// A bundle larger than this is refused before extraction.
    static let maxBundleBytes: Int64 = 4 << 30
    /// Suffix for the in-flight audio copy; never `.wav`, so never swept.
    static let partialSuffix = "partial"

    private let store: RecordingStore
    private let storageSettings: RecordingStorageSettings?
    private let profileStore: SpeakerProfileStore?
    private let voiceRecognition: VoiceRecognitionSettings?
    private let similarityThreshold: () -> Double
    private let speakerDirectory: SpeakerDirectory?
    /// Whether the app is currently transcribing / about to transcribe this
    /// id — replacing a recording under an in-flight pass would clobber it.
    private let isRecordingBusy: (UUID) -> Bool
    /// Whether an imported `.wav` gets the same AAC compression a local
    /// recording does once it lands. Tests turn it off so the audio filename
    /// they assert on isn't renamed underneath them.
    private let compressImportedWAV: Bool
    private let fileManager = FileManager.default
    private var queue: [URL] = []
    private let log = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "RecordingShare")

    init(store: RecordingStore,
         storageSettings: RecordingStorageSettings? = nil,
         profileStore: SpeakerProfileStore? = nil,
         voiceRecognition: VoiceRecognitionSettings? = nil,
         similarityThreshold: @escaping () -> Double = { 0.55 },
         speakerDirectory: SpeakerDirectory? = nil,
         isRecordingBusy: @escaping (UUID) -> Bool = { _ in false },
         compressImportedWAV: Bool = true) {
        self.store = store
        self.storageSettings = storageSettings
        self.profileStore = profileStore
        self.voiceRecognition = voiceRecognition
        self.similarityThreshold = similarityThreshold
        self.speakerDirectory = speakerDirectory
        self.isRecordingBusy = isRecordingBusy
        self.compressImportedWAV = compressImportedWAV
        sweepPartialFiles()
    }

    // MARK: - Entry points

    /// From the file-open handler or the File menu. Bundles queue up and
    /// stage one at a time, so several double-clicked files produce one
    /// sheet after another rather than a pile.
    func handleOpen(_ url: URL) {
        queue.append(url)
        pumpQueue()
    }

    /// File ▸ Import Shared Recording…
    func openInteractively() {
        let panel = NSOpenPanel()
        panel.title = "Import Shared Recording"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.milaShare]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(handleOpen)
    }

    func cancel() {
        if let pending {
            try? fileManager.removeItem(at: pending.stagingDirectory)
        }
        pending = nil
        pumpQueue()
    }

    private func pumpQueue() {
        guard pending == nil, !isStaging, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        // Claim the slot HERE, synchronously, not inside `stage`: the Task
        // below has not started when a second `handleOpen` arrives in the
        // same run-loop turn, and two concurrent stagings would race to set
        // `pending`, leaking the loser's staging directory.
        isStaging = true
        Task { await stage(next) }
    }

    // MARK: - Stage

    private func stage(_ url: URL) async {
        defer {
            isStaging = false
            pumpQueue()
        }
        // The file may live outside anything the app was granted (a download
        // the user double-clicked). Harmless when no scope is offered.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var staging: URL?
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw ShareManifest.LoadError.unreadable("It isn't a regular file.")
            }
            let bundleBytes = Int64(values.fileSize ?? 0)
            guard bundleBytes > 0 else {
                throw ShareManifest.LoadError.malformed("The file is empty.")
            }
            guard bundleBytes <= Self.maxBundleBytes else {
                throw ShareManifest.LoadError.malformed("The file is too large to be a Mila shared recording.")
            }
            if let free = try? store.recordingsDirectory
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage,
               free < bundleBytes * 2 {
                throw ShareManifest.LoadError.unreadable("There isn't enough free disk space to import it.")
            }

            let dir = fileManager.temporaryDirectory
                .appendingPathComponent("mila-share-import-\(UUID().uuidString)", isDirectory: true)
            staging = dir
            try await ZipArchiver.unzip(url, into: dir)

            // Only the fixed names are ever looked at — see the type comment.
            let manifestURL = dir.appendingPathComponent(ShareManifest.manifestEntryName)
            try requireRegularFile(manifestURL, within: dir,
                                   missing: ShareManifest.LoadError.malformed("It has no manifest."))
            let data: Data
            do {
                data = try Data(contentsOf: manifestURL)
            } catch {
                throw ShareManifest.LoadError.unreadable(error.localizedDescription)
            }
            let manifest = try ShareManifest.decode(data).validated()

            let audioURL = dir.appendingPathComponent(manifest.audio.fileName)
            try requireRegularFile(audioURL, within: dir,
                                   missing: ShareManifest.LoadError.integrity("Its audio entry is missing."))
            let audioBytes = Int64((try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
            guard audioBytes == manifest.audio.byteCount else {
                throw ShareManifest.LoadError.integrity("The audio's size doesn't match the manifest.")
            }
            let digest = try await Task.detached(priority: .userInitiated) {
                try FileDigest.sha256Hex(of: audioURL)
            }.value
            guard digest == manifest.audio.sha256.lowercased() else {
                throw ShareManifest.LoadError.integrity("The audio's checksum doesn't match the manifest.")
            }

            var text = ""
            if let transcript = manifest.transcript {
                let transcriptURL = dir.appendingPathComponent(transcript.fileName)
                try requireRegularFile(transcriptURL, within: dir,
                                       missing: ShareManifest.LoadError.integrity("Its transcript entry is missing."))
                text = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = TranscriptFormatter.joinedFullText(segments: manifest.recording.segments)
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !manifest.recording.segments.isEmpty else {
                throw ShareManifest.LoadError.malformed("It contains no transcript.")
            }

            let existing = store.recordings.first { $0.id == manifest.recording.id }
            if let existing, isRecordingBusy(existing.id) {
                throw ImportError.recordingBusy
            }
            let disposition: Disposition = existing.map { .update(existing: $0) } ?? .add

            pending = PendingImport(
                manifest: manifest,
                stagingDirectory: dir,
                audioURL: audioURL,
                transcriptText: text,
                sourceName: url.lastPathComponent,
                bundleByteCount: bundleBytes,
                disposition: disposition,
                wouldExceedStorageCap: capExceeded(incoming: manifest.audio.byteCount, replacing: existing) != nil,
                speakerPlan: makeSpeakerPlan(for: manifest))

            // The bundle's filename is whatever the sender called it — a
            // meeting title, a client — so it goes `.private`; the id, byte
            // count and disposition are the diagnostic.
            log.log("""
                staged \(url.lastPathComponent, privacy: .private) for import: \
                recording \(manifest.recording.id, privacy: .public), \
                \(bundleBytes, privacy: .public) bytes, \
                \(existing == nil ? "add" : "update", privacy: .public), \
                \(manifest.speakerProfiles?.count ?? 0, privacy: .public) voice profile(s)
                """)
        } catch {
            if let staging { try? fileManager.removeItem(at: staging) }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("""
                failed to stage shared recording: \
                \(ShareManifest.LoadError.logMessage(for: error), privacy: .public) \
                (\(String(describing: error), privacy: .private))
                """)
        }
    }

    /// An entry must be a regular file (not a symlink, not a directory) and
    /// must resolve inside the staging directory. `attributesOfItem` does
    /// not follow symlinks, which is the point.
    private func requireRegularFile(_ url: URL, within root: URL, missing: Error) throws {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { throw missing }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular,
              ObsidianPathSanitizer.isContained(url, in: root) else {
            throw ShareManifest.LoadError.malformed("One of its entries isn't an ordinary file.")
        }
    }

    private func makeSpeakerPlan(for manifest: ShareManifest) -> SpeakerProfileImportPlan {
        guard let profiles = manifest.speakerProfiles, !profiles.isEmpty,
              let profileStore, let voiceRecognition else { return .empty }
        let context = SpeakerProfileImportResolver.Context(
            localProfiles: profileStore.profiles,
            isEnabled: voiceRecognition.isEnabled,
            isConfigured: voiceRecognition.isConfigured,
            similarityThreshold: similarityThreshold(),
            senderDisplayName: manifest.exportedBy.name,
            alreadyImported: profileStore.importedShareTokens)
        return SpeakerProfileImportResolver.resolve(incoming: profiles,
                                                    speakerNames: manifest.recording.speakerNames,
                                                    bundleKey: manifest.bundleID.uuidString,
                                                    context: context)
    }

    /// The cap message when importing `incoming` bytes (less the audio of a
    /// recording being replaced) would exceed the storage limit; nil when
    /// it fits or no limit is configured. Same wording as the record-start
    /// gate in `QuickActionsController`.
    private func capExceeded(incoming: Int64, replacing existing: Recording?) -> String? {
        guard let storageSettings else { return nil }
        var used = store.currentUsageBytes()
        if let existing,
           let size = try? store.audioURL(for: existing).resourceValues(forKeys: [.fileSizeKey]).fileSize {
            used -= Int64(size)
        }
        guard used + incoming > storageSettings.limitBytes else { return nil }
        let usedGB = Double(used) / 1_073_741_824.0
        return String(
            format: "Storage limit reached (%.1f of %.0f GB used). Free up space or raise the limit in Settings ▸ Storage.",
            usedGB, storageSettings.limitGigabytes)
    }

    // MARK: - Confirm

    func confirm() async {
        guard let pending, !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        // `pending` is a value copy; the published slot can be cleared by
        // Cancel while the audio copy below is in flight. Every resumption
        // re-checks that THIS import is still the one on screen.
        let ticket = pending.id
        let manifest = pending.manifest
        let existing: Recording? = {
            if case .update(let e) = pending.disposition { return e }
            return nil
        }()

        // Authoritative cap check — the preview was computed at stage time.
        if let message = capExceeded(incoming: manifest.audio.byteCount, replacing: existing) {
            errorMessage = ImportError.storageCap(message).errorDescription
            return  // keep `pending` so the user can still cancel
        }
        if let existing, isRecordingBusy(existing.id) {
            errorMessage = ImportError.recordingBusy.errorDescription
            return
        }

        let destination = freshDestination(title: manifest.recording.title,
                                           extension: manifest.audio.format)
        let partial = destination.appendingPathExtension(Self.partialSuffix)
        let source = pending.audioURL
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: source, to: partial)
            }.value
        } catch {
            try? fileManager.removeItem(at: partial)
            // If Cancel already dismissed this import, it also removed the
            // staging directory — which is why the copy failed. Not an error.
            guard self.pending?.id == ticket else { return }
            finish(pending, error: ShareManifest.LoadError.unreadable(error.localizedDescription))
            return
        }
        guard self.pending?.id == ticket else {
            // Cancelled while copying: the user dismissed this import, so
            // nothing of it may reach the library or the voice profiles.
            try? fileManager.removeItem(at: partial)
            log.log("import of \(manifest.recording.id, privacy: .public) cancelled during the audio copy")
            return
        }

        // Voice profiles FIRST. A recording whose labels point at profiles
        // that were never created is wrong; profiles without the recording
        // are merely unused.
        var mapping: [String: String] = [:]
        if !pending.speakerPlan.isEmpty, let profileStore {
            mapping = SpeakerProfileImportApplier.apply(pending.speakerPlan, to: profileStore).nameMapping
        }

        // From here to `upsertImported` is one synchronous main-actor run:
        // the audio appears under its final name and the store learns about
        // it without an intervening suspension point.
        do {
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            finish(pending, error: ShareManifest.LoadError.unreadable(error.localizedDescription))
            return
        }
        var recording = manifest.recording.makeRecording(
            audioFileName: destination.lastPathComponent,
            fullText: pending.transcriptText,
            sharedBy: manifest.exportedBy.name,
            sharedAt: manifest.exportedAt,
            folder: existing?.folder)          // local wins for the folder
        recording.speakerNames = recording.speakerNames.mapValues { mapping[$0] ?? $0 }
        for name in Set(recording.speakerNames.values) {
            speakerDirectory?.add(name)
        }

        switch store.upsertImported(recording) {
        case .notSaved:
            // The store rolled itself back, so the audio is unreferenced
            // and removing it leaves no trace of the attempt.
            try? fileManager.removeItem(at: destination)
            finish(pending, error: ImportError.saveFailed)
            return
        case .savedWithoutTranscript:
            // The row references the audio; the audio must stay. `load()`
            // rebuilds the text from the segments.
            log.error("imported \(recording.id, privacy: .public) but its .txt sidecar did not land")
        case .saved:
            break
        }

        if let existing, existing.audioFileName != recording.audioFileName {
            for url in [store.audioURL(for: existing), store.transcriptURL(for: existing),
                        store.summaryURL(for: existing), store.subtitleURL(for: existing)] {
                try? fileManager.removeItem(at: url)
            }
        }
        try? TranscriptExporter.writeSRT(for: recording, in: store.recordingsDirectory)

        log.log("""
            imported shared recording \(recording.id, privacy: .public) \
            (\(existing == nil ? "added" : "replaced", privacy: .public), \
            \(manifest.audio.byteCount, privacy: .public) audio bytes)
            """)
        finish(pending, error: nil)
        lastImport = Completion(recordingID: recording.id)

        // A shared .wav gets the same storage treatment as a local one.
        if compressImportedWAV, manifest.audio.format == "wav" {
            let id = recording.id
            Task { await store.compressRecordingAudio(id: id) }
        }
    }

    private func finish(_ pending: PendingImport, error: Error?) {
        try? fileManager.removeItem(at: pending.stagingDirectory)
        self.pending = nil
        if let error {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("""
                import failed: \(ShareManifest.LoadError.logMessage(for: error), privacy: .public) \
                (\(String(describing: error), privacy: .private))
                """)
        }
        pumpQueue()
    }

    /// A library filename minted HERE — `freshAudioURL`'s `<title> <stamp>-
    /// <uuid6>` shape with the bundle's audio extension, never a name from
    /// the archive. Loops on the vanishingly unlikely collision.
    private func freshDestination(title: String, extension ext: String) -> URL {
        let stem = ObsidianPathSanitizer.nameFragment(title)
        while true {
            let url = store.freshAudioURL(suggestedName: stem.isEmpty ? nil : stem)
                .deletingPathExtension()
                .appendingPathExtension(ext)
            let partial = url.appendingPathExtension(Self.partialSuffix)
            if !fileManager.fileExists(atPath: url.path), !fileManager.fileExists(atPath: partial.path) {
                return url
            }
        }
    }

    /// Remove `*.partial` left by a crash between the audio copy and the
    /// store write. They were never referenced by `recordings.json`.
    private func sweepPartialFiles() {
        guard let names = try? fileManager.contentsOfDirectory(atPath: store.recordingsDirectory.path) else {
            return
        }
        for name in names where (name as NSString).pathExtension == Self.partialSuffix {
            try? fileManager.removeItem(at: store.recordingsDirectory.appendingPathComponent(name))
        }
    }
}
