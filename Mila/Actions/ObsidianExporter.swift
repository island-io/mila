import Foundation
import MilaKit

/// Writes a completed recording into the configured Obsidian vault as a
/// Markdown note, then optionally kicks the git sync.
///
/// Content is **summary + action items** when a summary exists; when it
/// doesn't (summaries off, LLM unconfigured, or generation failed) it falls
/// back to **transcript + action items** so export stays independent of the
/// LLM. One `.md` per recording, `<date> <title>.md`, into `vault/subfolder`
/// — suffixed with a slice of the recording ID when a different recording has
/// already taken that name (see `noteTarget`).
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
        // It also covers what no naming rule can — a symlink inside the vault
        // whose target is outside it, which is spelled entirely under the vault.
        guard ObsidianPathSanitizer.isContained(destDir, in: vault, fileManager: fileManager) else {
            print("ObsidianExporter: refusing to write outside the vault: \(destDir.path)")
            return nil
        }

        do {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
        } catch {
            print("ObsidianExporter: failed to create \(destDir.path): \(error)")
            return nil
        }

        // The key is scoped to the vault. The stored value is a path *relative
        // to the vault it was written into*, so resolving it against whatever
        // vault happens to be configured now would, after the user switches
        // vaults, delete `<newVault>/<oldRelativePath>` — an unrelated file, or
        // nothing — and orphan the real note in the previous vault.
        //
        // Resolved before the filename, because the name this recording gets
        // depends on what it was called last time — see `noteTarget`.
        let key = Self.indexKey(vault: vault, id: recording.id)
        migrateLegacyIndexEntry(&index, key: key, vault: vault, id: recording.id)

        let target = noteTarget(for: recording, in: destDir, vault: vault, index: index, key: key)
        // Re-checked for the file itself, not just its directory: the note name
        // could already exist as a symlink pointing out of the vault.
        guard ObsidianPathSanitizer.isContained(target, in: vault, fileManager: fileManager) else {
            print("ObsidianExporter: refusing to write outside the vault: \(target.path)")
            return nil
        }
        let newRelative = Self.relativePath(of: target, vault: vault)
        var changedPaths: [URL] = [target]

        // Overwrite discipline: if we wrote a differently-named file for this
        // recording before (title changed / moved to another folder), remove it.
        if let prevRelative = index[key], prevRelative != newRelative {
            let old = vault.appendingPathComponent(prevRelative)
            // Never follow a stored path back out of the vault.
            if ObsidianPathSanitizer.isContained(old, in: vault, fileManager: fileManager) {
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

    // MARK: - Note naming

    /// Where this recording's note goes: `<date> <title>.md`, disambiguated
    /// when that name is already spoken for by a *different* recording.
    ///
    /// The plain name is not unique. Titles default to the capture source
    /// rather than to anything per-recording — two system-audio captures on the
    /// same day are both "System Audio" — so without this, the second export
    /// silently overwrote the first and one note was simply lost. The index is
    /// keyed by recording ID, so it never noticed: both recordings held their
    /// own entry pointing at the same file, and the rename cleanup saw nothing
    /// to delete.
    ///
    /// **Stickiness is the whole point.** A re-export (re-transcription, a
    /// summary landing, a backfill sweep) must resolve to the file it wrote
    /// last time, not to a fresh name — otherwise every pass would leave
    /// another copy behind. Two things provide it:
    ///
    ///  * the candidate names are *derived from the recording ID*, not from a
    ///    counter over the directory, so they don't shift when neighbouring
    ///    notes come and go; and
    ///  * whichever candidate the index already records for this recording wins
    ///    outright, before any availability check — so a note that had to be
    ///    disambiguated keeps its suffix even once the plain name frees up.
    private func noteTarget(for recording: Recording,
                            in destDir: URL,
                            vault: URL,
                            index: [String: String],
                            key: String) -> URL {
        let candidates = Self.nameCandidates(for: recording)
        let previous = index[key]

        // Sticky: the name we wrote for this recording last time, as long as
        // it's still one of the names this recording would pick today. (After
        // a retitle none of them match, and the rename path takes over.)
        for name in candidates {
            let url = destDir.appendingPathComponent(name)
            if previous == Self.relativePath(of: url, vault: vault) { return url }
        }

        // Both signals matter. The index catches the same-day/same-title clash
        // even when the other note has been synced away or not yet written;
        // the disk catches what the index can't know about — a note from a
        // build before this index existed, a copy arriving over git sync, or
        // a file the user wrote by hand and would not thank us for clobbering.
        let claimed = Self.pathsClaimedByOtherRecordings(index, vault: vault, id: recording.id)
        for name in candidates {
            let url = destDir.appendingPathComponent(name)
            let relative = Self.relativePath(of: url, vault: vault)
            if !claimed.contains(relative) && !fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        // Unreachable in practice: the last candidate carries the full
        // recording UUID, which no other recording can produce. Falling back
        // to it (rather than to the plain name) keeps the worst case a
        // collision we lose to, never an overwrite.
        return destDir.appendingPathComponent(candidates[candidates.count - 1])
    }

    /// The note names this recording will accept, in order of preference:
    /// the plain `<date> <title>.md`, then the same stem suffixed with a short
    /// prefix of the recording UUID, then with the whole thing.
    ///
    /// Deterministic by construction — the same recording yields the same list
    /// on every run, which is what lets `noteTarget` be idempotent. The short
    /// form is what a user will normally see; the full form exists only so the
    /// list cannot run out, since two distinct recordings can never share it.
    ///
    /// Length stays inside the 255-byte component limit: the stem is capped at
    /// 180 bytes by `ObsidianPathSanitizer.nameFragment` plus an 11-byte date
    /// prefix, and the longest suffix here adds 37 more.
    static func nameCandidates(for recording: Recording) -> [String] {
        let base = fileName(for: recording)
        let stem = base.hasSuffix(".md") ? String(base.dropLast(3)) : base
        let uuid = recording.id.uuidString.lowercased()
        return [base, "\(stem) \(uuid.prefix(8)).md", "\(stem) \(uuid).md"]
    }

    /// Relative paths inside `vault` that the index records for some recording
    /// other than `id`.
    ///
    /// Legacy bare-UUID keys are skipped on purpose: they carry no vault, so
    /// attributing their path to *this* vault could suppress the plain name on
    /// the strength of a note that lives somewhere else entirely.
    private static func pathsClaimedByOtherRecordings(_ index: [String: String],
                                                      vault: URL,
                                                      id: UUID) -> Set<String> {
        let prefix = "\(vault.standardized.path)#"
        var claimed: Set<String> = []
        for (key, relative) in index where key.hasPrefix(prefix) {
            let suffix = String(key.dropFirst(prefix.count))
            // A vault path may itself contain "#", so a prefix match alone
            // doesn't prove the key belongs to this vault — the remainder has
            // to be exactly a UUID.
            guard let other = UUID(uuidString: suffix), other != id else { continue }
            claimed.insert(relative)
        }
        return claimed
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
        guard ObsidianPathSanitizer.isContained(candidate, in: vault, fileManager: fileManager),
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
    ///
    /// The *preferred* name, not necessarily the one on disk: it is not unique
    /// per recording, so `noteTarget` may pick a suffixed variant instead. Use
    /// `nameCandidates(for:)` for the full set.
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
