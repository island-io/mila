import Foundation

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
        var index = writtenIndex()
        guard let write = writeNote(recording, vault: vault, index: &index) else { return nil }
        setWrittenIndex(index)

        if settings.gitSyncEnabled {
            // Single-line: a title with an embedded newline would otherwise
            // turn the commit subject into a subject + body in the user's
            // vault history.
            let title = Self.singleLine(recording.title)
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

        // The index is loaded once and stored once. Per-note persistence would
        // re-serialize the whole dictionary for every recording, which is what
        // actually makes a large backfill expensive — not the file writes.
        var index = writtenIndex()
        var changed: [URL] = []
        // Counted separately from `changed`: a rename contributes *two* paths
        // (the new file and the removed old one) for a single written note, so
        // `changed.count` would over-report both the UI result and the commit
        // subject after any title or folder change.
        var written = 0
        for recording in recordings {
            guard let write = writeNote(recording, vault: vault, index: &index) else { continue }
            changed.append(contentsOf: write.changedPaths)
            written += 1
        }
        setWrittenIndex(index)
        guard !changed.isEmpty else { return 0 }

        if settings.gitSyncEnabled {
            let message = "Sync \(written) Mila transcript\(written == 1 ? "" : "s")"
            kickGitSync(vault: vault, changedPaths: changed, commitMessage: message)
        }
        return written
    }

    /// File `recording` into the vault (no git). Returns the written file plus
    /// the paths that changed on disk (the new file and any old file removed by
    /// a rename), or nil when there's nothing to write / the write fails.
    private func writeNote(_ recording: Recording,
                           vault: URL,
                           index: inout [String: String]) -> (written: URL, changedPaths: [URL])? {
        // Never file a recording the user has thrown away. The summary hook
        // can land after a trash action (the LLM call is in flight when the
        // user deletes), and "I deleted it and it still turned up in my vault"
        // is the worst possible surprise from a background exporter.
        guard !recording.isTrashed else { return nil }
        guard Self.hasContent(recording), let destDir = destinationDirectory(for: recording) else {
            return nil
        }
        // Defence in depth, immediately before the first thing that touches
        // the disk: the sanitizer makes an escaping component impossible, and
        // this makes a regression in it non-exploitable rather than silent.
        guard ObsidianPathSanitizer.isContained(destDir, in: vault) else {
            print("ObsidianExporter: refusing to write outside the vault: \(destDir.path)")
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
        //
        // The key is scoped to the vault. The stored value is a path *relative
        // to the vault it was written into*, so resolving it against whatever
        // vault happens to be configured now would, after the user switches
        // vaults, delete `<newVault>/<oldRelativePath>` — an unrelated file, or
        // nothing — and orphan the real note in the previous vault.
        let key = Self.indexKey(vault: vault, id: recording.id)
        migrateLegacyIndexEntry(&index, key: key, vault: vault, id: recording.id)
        if let prevRelative = index[key], prevRelative != newRelative {
            let old = vault.appendingPathComponent(prevRelative)
            // Never follow a stored path back out of the vault.
            if ObsidianPathSanitizer.isContained(old, in: vault) {
                try? fileManager.removeItem(at: old)
                changedPaths.append(old)
            }
        }

        do {
            try Self.markdown(for: recording).write(to: target, atomically: true, encoding: .utf8)
        } catch {
            print("ObsidianExporter: failed to write \(target.path): \(error)")
            return nil
        }
        index[key] = newRelative
        return (target, changedPaths)
    }

    /// Index keys written before the index was vault-scoped are bare UUIDs.
    /// Adopt such an entry into the current vault's namespace only when the
    /// file it names actually exists in *this* vault — that is the only
    /// evidence that it is a note we wrote here. Otherwise it belongs to a
    /// vault the user has since switched away from, and must not be allowed to
    /// drive a delete. Either way the legacy key is dropped, so the migration
    /// runs at most once per recording.
    private func migrateLegacyIndexEntry(_ index: inout [String: String],
                                         key: String,
                                         vault: URL,
                                         id: UUID) {
        let legacyKey = id.uuidString
        guard let legacy = index[legacyKey] else { return }
        index[legacyKey] = nil
        guard index[key] == nil else { return }
        let candidate = vault.appendingPathComponent(legacy)
        guard ObsidianPathSanitizer.isContained(candidate, in: vault),
              fileManager.fileExists(atPath: candidate.path) else { return }
        index[key] = legacy
    }

    /// The vault destination for `recording`: the configured subfolder, plus a
    /// nested folder mirroring the recording's Mila folder when it has one.
    private func destinationDirectory(for recording: Recording) -> URL? {
        guard let base = settings.destinationDirectory else { return nil }
        let folder = (recording.folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { return base }
        // `directoryComponent`, not `sanitizedTitle`: a Mila folder literally
        // named ".." would otherwise append a real parent-directory component
        // and file the note outside the configured subfolder.
        let safe = ObsidianPathSanitizer.directoryComponent(folder)
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

    /// Vault-scoped index key. `standardized` (lexical) rather than
    /// `standardizedFileURL` so the key doesn't change with the filesystem's
    /// mood — see `ObsidianPathSanitizer.isContained`.
    static func indexKey(vault: URL, id: UUID) -> String {
        "\(vault.standardized.path)#\(id.uuidString)"
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

    /// Markdown headings and list items are line-based constructs, so any user
    /// text placed on such a line has to be collapsed to one line first — a
    /// newline in a title would otherwise split the `# ` heading, and one in an
    /// action item would break the `- [ ] ` checkbox into loose body text.
    static func singleLine(_ raw: String) -> String {
        raw.components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the note body: `# title`, then the summary (or a `## Transcript`
    /// fallback), then a `## Action items` checklist when present.
    static func markdown(for recording: Recording) -> String {
        let title = singleLine(recording.title)
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
            out += items.map { "- [ ] \(singleLine($0.text))" }.joined(separator: "\n")
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
    /// safe single-line filename component. Length-capped on a UTF-8 budget so
    /// a very long title can't blow past the 255-byte component limit and make
    /// the write fail.
    ///
    /// Safe to leave leading dots in place here: `fileName` always prefixes the
    /// date, so the result can never be `.`, `..` or a dotfile. Directory names
    /// have no such prefix and go through `ObsidianPathSanitizer
    /// .directoryComponent` instead.
    static func sanitizedTitle(_ title: String) -> String {
        ObsidianPathSanitizer.nameFragment(title)
    }
}
