import Foundation
import MilaKit

/// Writes a completed recording into the configured Obsidian vault as a
/// Markdown note, then optionally kicks the git sync.
///
/// Content is **summary + action items** when a summary exists; when it
/// doesn't (summaries off, LLM unconfigured, or generation failed) it falls
/// back to **transcript + action items** so export stays independent of the
/// LLM. One `.md` per recording, `<date> <title>.md`, into `vault/subfolder`.
///
/// Idempotency: a per-recording seen-index (Drive-importer discipline) maps the
/// recording ID to its last-written relative path, so a re-transcription (or a
/// title edit) overwrites/renames the same note instead of leaving duplicates.
///
/// The `pending` set is the sequencing gate: a fresh completion is marked
/// pending, and the actual write happens from `RecordingSummarizer`'s
/// completion hook once the summary is final. Backfilled recordings are never
/// marked pending, so a launch-time summary sweep can't spam the vault.
@MainActor
final class ObsidianExporter: ObservableObject {
    static let writtenIndexKey = "obsidian.writtenIndex"

    private let settings: ObsidianVaultSettings
    private let gitSyncer: ObsidianGitSyncer
    private let defaults: UserDefaults
    private let fileManager: FileManager

    private var pending: Set<UUID> = []

    init(settings: ObsidianVaultSettings,
         gitSyncer: ObsidianGitSyncer = ObsidianGitSyncer(),
         defaults: UserDefaults = .standard,
         fileManager: FileManager = .default) {
        self.settings = settings
        self.gitSyncer = gitSyncer
        self.defaults = defaults
        self.fileManager = fileManager
    }

    // MARK: - Pending gate

    func markPending(_ id: UUID) { pending.insert(id) }
    func isPending(_ id: UUID) -> Bool { pending.contains(id) }
    func clearPending(_ id: UUID) { pending.remove(id) }

    // MARK: - Export

    /// Write `recording` into the vault. No-op (returns nil) when the feature
    /// is disabled, no vault is picked, or the recording has nothing worth
    /// filing. Returns the written file URL on success.
    @discardableResult
    func export(_ recording: Recording) -> URL? {
        guard settings.enabled, let vault = settings.vaultURL else { return nil }
        guard let write = writeNote(recording, vault: vault) else { return nil }

        if settings.gitSyncEnabled {
            let title = recording.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = "Add transcript: \(title.isEmpty ? "Untitled recording" : title)"
            kickGitSync(vault: vault, changedPaths: write.changedPaths, commitMessage: message)
        }
        return write.written
    }

    /// Backfill: write every provided recording into the vault, then kick a
    /// single git sync covering all of them. Used by "Sync existing
    /// transcripts". Returns the count of notes actually written.
    @discardableResult
    func exportAll(_ recordings: [Recording]) -> Int {
        guard settings.enabled, let vault = settings.vaultURL else { return 0 }

        var changed: [URL] = []
        for recording in recordings {
            guard let write = writeNote(recording, vault: vault) else { continue }
            changed.append(contentsOf: write.changedPaths)
        }
        guard !changed.isEmpty else { return 0 }

        if settings.gitSyncEnabled {
            let message = "Sync \(changed.count) Mila transcript\(changed.count == 1 ? "" : "s")"
            kickGitSync(vault: vault, changedPaths: changed, commitMessage: message)
        }
        return changed.count
    }

    /// File `recording` into the vault (no git). Returns the written file plus
    /// the paths that changed on disk (the new file and any old file removed by
    /// a rename), or nil when there's nothing to write / the write fails.
    private func writeNote(_ recording: Recording,
                           vault: URL) -> (written: URL, changedPaths: [URL])? {
        guard Self.hasContent(recording), let destDir = destinationDirectory(for: recording) else {
            return nil
        }

        do {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            print("ObsidianExporter: failed to create \(destDir.path): \(error)")
            return nil
        }

        let target = destDir.appendingPathComponent(Self.fileName(for: recording))
        let newRelative = Self.relativePath(of: target, vault: vault)
        var changedPaths: [URL] = [target]

        // Overwrite discipline: if we wrote a differently-named file for this
        // recording before (title changed / moved to another folder), remove it.
        var index = writtenIndex()
        let key = recording.id.uuidString
        if let prevRelative = index[key], prevRelative != newRelative {
            let old = vault.appendingPathComponent(prevRelative)
            try? fileManager.removeItem(at: old)
            changedPaths.append(old)
        }

        do {
            try Self.markdown(for: recording).write(to: target, atomically: true, encoding: .utf8)
        } catch {
            print("ObsidianExporter: failed to write \(target.path): \(error)")
            return nil
        }
        index[key] = newRelative
        setWrittenIndex(index)
        return (target, changedPaths)
    }

    /// The vault destination for `recording`: the configured subfolder, plus a
    /// nested folder mirroring the recording's Mila folder when it has one.
    private func destinationDirectory(for recording: Recording) -> URL? {
        guard let base = settings.destinationDirectory else { return nil }
        let folder = (recording.folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { return base }
        let safe = Self.sanitizedTitle(folder)
        guard !safe.isEmpty else { return base }
        return base.appendingPathComponent(safe, isDirectory: true)
    }

    private func kickGitSync(vault: URL, changedPaths: [URL], commitMessage: String) {
        let rawBranch = settings.gitBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = rawBranch.isEmpty ? ObsidianVaultSettings.defaultBranch : rawBranch
        let syncer = gitSyncer
        Task { @MainActor in
            let error = await syncer.sync(vault: vault,
                                          changedPaths: changedPaths,
                                          branch: branch,
                                          commitMessage: commitMessage)
            self.settings.lastSyncError = error
        }
    }

    // MARK: - Seen-index

    private func writtenIndex() -> [String: String] {
        defaults.dictionary(forKey: Self.writtenIndexKey) as? [String: String] ?? [:]
    }

    private func setWrittenIndex(_ index: [String: String]) {
        defaults.set(index, forKey: Self.writtenIndexKey)
    }

    private static func relativePath(of url: URL, vault: URL) -> String {
        let base = vault.path.hasSuffix("/") ? vault.path : vault.path + "/"
        if url.path.hasPrefix(base) { return String(url.path.dropFirst(base.count)) }
        return url.lastPathComponent
    }

    // MARK: - Formatting (pure, unit-tested)

    /// True when the recording has anything worth writing (a summary,
    /// transcript text, or action items).
    static func hasContent(_ recording: Recording) -> Bool {
        if !(recording.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if !recording.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let items = recording.actionItems, !items.isEmpty { return true }
        return false
    }

    /// Build the note body: `# title`, then the summary (or a `## Transcript`
    /// fallback), then a `## Action items` checklist when present.
    static func markdown(for recording: Recording) -> String {
        let title = recording.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = "# \(title.isEmpty ? "Untitled recording" : title)\n"

        let summary = (recording.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            out += "\n\(summary)\n"
        } else {
            let transcript = TranscriptFormatter.plainText(
                segments: recording.segments,
                fallback: recording.fullText,
                names: recording.speakerNames
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                out += "\n## Transcript\n\n\(transcript)\n"
            }
        }

        if let items = recording.actionItems, !items.isEmpty {
            out += "\n## Action items\n\n"
            out += items.map { "- [ ] \($0.text)" }.joined(separator: "\n")
            out += "\n"
        }
        return out
    }

    /// `<yyyy-MM-dd> <title>.md`, sanitized for the filesystem.
    static func fileName(for recording: Recording) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let datePart = formatter.string(from: recording.createdAt)
        let safeTitle = sanitizedTitle(recording.title)
        let base = safeTitle.isEmpty ? datePart : "\(datePart) \(safeTitle)"
        return base + ".md"
    }

    /// Strip path-hostile characters and collapse whitespace so the title is a
    /// safe single-line filename component.
    static func sanitizedTitle(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
            .union(.newlines)
            .union(.controlCharacters)
        let stripped = title.components(separatedBy: invalid).joined(separator: " ")
        return stripped
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
    }
}
