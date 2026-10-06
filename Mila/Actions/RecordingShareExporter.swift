import AppKit
import Foundation
import MilaKit
import os
import UniformTypeIdentifiers

private let shareLog = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "RecordingShare")

/// Builds a `.milashare` bundle for one recording: `manifest.json`,
/// `audio.<wav|m4a>` (copied as-is, never re-encoded) and `transcript.txt`,
/// zipped by `ZipArchiver`. See `ShareManifest` for the format.
@MainActor
enum RecordingShareExporter {

    enum ExportError: LocalizedError, Equatable {
        case notTranscribed
        case audioMissing
        case unsupportedAudioFormat(String)

        var errorDescription: String? {
            switch self {
            case .notTranscribed:
                return "This recording hasn't finished transcribing, so there's nothing to share yet."
            case .audioMissing:
                return "The recording's audio file is missing, so it can't be shared."
            case .unsupportedAudioFormat(let ext):
                return "The recording's audio is in a format (.\(ext)) that can't be shared."
            }
        }
    }

    /// `UserDefaults` key for a user-chosen display name in bundles this Mac
    /// exports. Absent → the account's full name.
    static let exporterNameKey = "sharing.exporterName"

    /// Only completed, untrashed recordings with a transcript. The importer
    /// relies on this: it refuses a bundle with no transcript and always
    /// marks what it imports `.completed`.
    static func canExport(_ recording: Recording) -> Bool {
        !recording.isTrashed
            && recording.status == .completed
            && (!recording.segments.isEmpty || !recording.fullText.isEmpty)
    }

    /// `<title>.milashare`, with the title made safe for a filename.
    static func suggestedFileName(for recording: Recording) -> String {
        let stem = ObsidianPathSanitizer.nameFragment(recording.title)
        return (stem.isEmpty ? "Shared recording" : stem) + "." + ShareManifest.fileExtension
    }

    /// Who the bundle says shared it. A display name, never an email: the
    /// receiver builds "Alex (from Daniel)" out of it.
    static func exporterName(defaults: UserDefaults = .standard) -> String {
        if let custom = defaults.string(forKey: exporterNameKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        return full.isEmpty ? NSUserName() : full
    }

    /// `nonisolated` so it can serve as a default argument (those are
    /// evaluated outside the actor); `Bundle.main` is safe from anywhere.
    nonisolated static var currentAppInfo: ShareManifest.AppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return ShareManifest.AppInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?")
    }

    /// Build the bundle into a fresh temp directory and return the archive's
    /// URL (`<tmp>/mila-share-<uuid>/<suggestedFileName>`). The caller moves
    /// it where it belongs and removes the parent directory.
    static func buildBundle(for recording: Recording,
                            store: RecordingStore,
                            profiles: [SharedSpeakerProfile] = [],
                            exportedBy: String,
                            now: Date = Date(),
                            appInfo: ShareManifest.AppInfo? = currentAppInfo) async throws -> URL {
        guard canExport(recording) else { throw ExportError.notTranscribed }
        let audioURL = store.audioURL(for: recording)
        let fm = FileManager.default
        guard fm.fileExists(atPath: audioURL.path) else { throw ExportError.audioMissing }
        let ext = audioURL.pathExtension.lowercased()
        guard ShareManifest.allowedAudioExtensions.contains(ext) else {
            throw ExportError.unsupportedAudioFormat(ext)
        }

        let staging = fm.temporaryDirectory
            .appendingPathComponent("mila-share-\(UUID().uuidString)", isDirectory: true)
        let payload = staging.appendingPathComponent("payload", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)

        do {
            // Copy + hash off the main actor: a two-hour .wav is hundreds of MB.
            let audioEntry = payload.appendingPathComponent("\(ShareManifest.audioEntryStem).\(ext)")
            let (byteCount, digest) = try await Task.detached(priority: .userInitiated) {
                () throws -> (Int64, String) in
                try FileManager.default.copyItem(at: audioURL, to: audioEntry)
                let size = try audioEntry.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                return (Int64(size), try FileDigest.sha256Hex(of: audioEntry))
            }.value

            let text = recording.fullText.isEmpty
                ? TranscriptFormatter.joinedFullText(segments: recording.segments)
                : recording.fullText
            var transcript: ShareManifest.Transcript?
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try text.write(to: payload.appendingPathComponent(ShareManifest.transcriptEntryName),
                               atomically: true, encoding: .utf8)
                transcript = ShareManifest.Transcript(fileName: ShareManifest.transcriptEntryName)
            }

            let manifest = ShareManifest(
                version: ShareManifest.currentVersion,
                bundleID: UUID(),
                exportedAt: now,
                exportedBy: .init(name: exportedBy),
                app: appInfo,
                recording: .init(sharing: recording),
                audio: .init(fileName: audioEntry.lastPathComponent, format: ext,
                             byteCount: byteCount, sha256: digest),
                transcript: transcript,
                speakerProfiles: profiles.isEmpty ? nil : profiles)
            try ShareManifest.encoder().encode(manifest)
                .write(to: payload.appendingPathComponent(ShareManifest.manifestEntryName),
                       options: .atomic)

            let archive = staging.appendingPathComponent(suggestedFileName(for: recording))
            try await ZipArchiver.zipContents(of: payload, to: archive)
            try? fm.removeItem(at: payload)

            shareLog.log("""
                built share bundle for \(recording.id, privacy: .public) \
                (\(byteCount, privacy: .public) audio bytes, \
                \(profiles.count, privacy: .public) voice profile(s))
                """)
            return archive
        } catch {
            try? fm.removeItem(at: staging)
            // `localizedDescription` quotes paths, i.e. the recording title.
            shareLog.error("""
                share bundle failed for \(recording.id, privacy: .public): \
                \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public) \
                (\(error.localizedDescription, privacy: .private))
                """)
            throw error
        }
    }

    /// Save-panel flow: ask where first (a cheap cancel), then build, move
    /// into place and reveal in Finder. Returns nil when the user cancelled.
    static func exportInteractively(_ recording: Recording,
                                    store: RecordingStore,
                                    profiles: [SharedSpeakerProfile] = []) async throws -> URL? {
        let panel = NSSavePanel()
        panel.title = "Share Recording"
        panel.prompt = "Save"
        panel.allowedContentTypes = [.milaShare]
        panel.nameFieldStringValue = suggestedFileName(for: recording)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }

        let built = try await buildBundle(for: recording, store: store, profiles: profiles,
                                          exportedBy: exporterName())
        let fm = FileManager.default
        defer { try? fm.removeItem(at: built.deletingLastPathComponent()) }
        // The panel already asked about replacing an existing file.
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: built, to: destination)
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        return destination
    }
}
