import Foundation
import Combine
import OSLog

/// Bridges the iPhone Voice Memos library into Mila's transcription queue.
///
/// Responsibilities:
///  - **Backfill:** when the user enables sync or picks a new folder, import
///    every not-yet-seen recording from the selected folders and enqueue it.
///  - **Ongoing sync:** an FSEvents watcher on the Voice Memos folder notices
///    newly iCloud-synced recordings and imports the eligible ones.
///  - **Dedup:** every imported recording carries its `ZUNIQUEID` in
///    `Recording.voiceMemoUniqueID`; a rescan skips anything already present,
///    so restarts / repeated FSEvents bursts never re-import a memo.
///  - **Filtering:** short pocket recordings, memos before the start-date
///    cutoff, and `.composition` (multi-take) bundles are skipped, with counts
///    surfaced. Modern `.qta` (QuickTime-container) memos import normally —
///    `AVAudioFile`/`reencode` decodes their standard audio track.
///
/// Imports reuse `FileTranscriber.importFile`, which re-encodes into the
/// library and enqueues exactly like a drag-and-drop import — no new
/// transcription infrastructure.
@MainActor
final class VoiceMemosImporter: ObservableObject {
    private let store: RecordingStore
    private let transcription: TranscriptionService
    private let settings: VoiceMemosSettings
    private let languageSettings: RecordingLanguageSettings

    /// Reader over the folder the user granted access to (falling back to the
    /// standard location, which is what a Full-Disk-Access user already sees).
    /// Rebuilt each access so it always reflects the current grant.
    private var library: VoiceMemosLibrary {
        VoiceMemosLibrary(recordingsDirectory: settings.grantedFolderURL
                          ?? VoiceMemosLibrary.defaultRecordingsDirectory)
    }

    private let log = Logger(subsystem: "io.island.whisper.IslandWhisper", category: "VoiceMemos")

    /// Mila folder that synced Voice Memos are filed into so they're grouped
    /// together in the sidebar instead of mixed into All Transcripts
    /// (issue #57, part 4). One shared folder — simple and predictable; the
    /// per-source origin is tracked separately on `Recording.voiceMemoFolderUUID`.
    static let syncedFolderName = "Voice Memos"

    /// Per-run tally the Settings status line reads to explain what the last
    /// sync did — especially *why* it imported less than the folder count
    /// (before the start-date cutoff, not downloaded yet, failed to decode…).
    struct SyncSummary: Equatable {
        var imported = 0
        var failedImport = 0        // attempted but errored (couldn't decode/re-encode)
        var skippedOlder = 0        // recorded before the start-date cutoff
        var skippedShort = 0        // sub-minDurationSeconds pocket taps
        var skippedComposition = 0  // multi-take .composition bundles
        var skippedMissing = 0      // not downloaded from iCloud yet

        var totalHeldBack: Int {
            failedImport + skippedOlder + skippedShort + skippedComposition + skippedMissing
        }
    }

    /// Pure classification of a scan: which not-yet-imported memos are eligible
    /// to import, plus the tally of why the rest were held back. Split out of
    /// `sync()` so the "is there real work?" decision — the one that gates the
    /// visible "Syncing…" state — is testable without a database or filesystem,
    /// and so an idle rescan that imports nothing never flips the UI (issue #57,
    /// the "Last synced" flicker).
    struct ImportPlan: Equatable {
        var toImport: [VoiceMemosLibrary.Memo] = []
        var summary = SyncSummary()

        /// True only when the scan will actually import something — the sole
        /// case that should surface a "Syncing…" spinner to the user.
        var hasVisibleWork: Bool { !toImport.isEmpty }
    }

    /// Decide what a scan would do, given the memos read from the library and
    /// the dedup/cutoff inputs. Pure (no I/O beyond the injected `fileExists`
    /// probe) so it's unit-testable. Mirrors the eligibility order the old
    /// inline loop used: start-date cutoff first (so its count reflects the
    /// user's date choice), then composition, then too-short, then not-yet-
    /// downloaded.
    static func plan(memos: [VoiceMemosLibrary.Memo],
                     alreadyImported: Set<String>,
                     startDate: Date,
                     minDuration: Double,
                     fileExists: (URL) -> Bool) -> ImportPlan {
        var plan = ImportPlan()
        for memo in memos where !alreadyImported.contains(memo.uniqueID) {
            if memo.date < startDate { plan.summary.skippedOlder += 1; continue }
            if memo.isComposition { plan.summary.skippedComposition += 1; continue }
            if memo.duration < minDuration { plan.summary.skippedShort += 1; continue }
            guard fileExists(memo.fileURL) else { plan.summary.skippedMissing += 1; continue }
            plan.toImport.append(memo)
        }
        return plan
    }

    /// Last successful sync timestamp, for the Settings status line.
    @Published private(set) var lastSyncDate: Date?
    /// Recordings enqueued by the most recent sync.
    @Published private(set) var lastImportedCount = 0
    /// Cumulative recordings imported this session.
    @Published private(set) var totalImported = 0
    /// Breakdown of the most recent sync run (imported + why others skipped).
    @Published private(set) var lastSummary = SyncSummary()
    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?

    private var watcher: DirectoryWatcher?
    private var cancellables: Set<AnyCancellable> = []
    private var started = false
    /// Coalesces FSEvents bursts and overlapping triggers into one run.
    private var pendingResync = false
    /// A scan is running. Distinct from the *published* `isSyncing`, which now
    /// only reflects user-visible import work (issue #57): a scan that imports
    /// nothing runs with `scanInFlight == true` but never flips `isSyncing`, so
    /// the status line stays steady. This is the flag the coalescing guard
    /// keys on so two scans never overlap.
    private var scanInFlight = false

    init(store: RecordingStore,
         transcription: TranscriptionService,
         settings: VoiceMemosSettings,
         languageSettings: RecordingLanguageSettings) {
        self.store = store
        self.transcription = transcription
        self.settings = settings
        self.languageSettings = languageSettings
    }

    /// Wire up settings observation + the watcher, and run an initial sync.
    /// Called once from MilaApp's launch `.task`.
    func start() {
        guard !started else { return }
        started = true
        // React to the user toggling sync on/off or changing folder choices.
        // `objectWillChange` (rather than merging the `@Published` projections)
        // fires only on an actual change — no initial-value emissions to skip —
        // and the debounce coalesces dragging through several checkboxes into
        // one sync.
        settings.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in self?.reconfigure() }
            .store(in: &cancellables)

        reconfigure()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Apply the current settings: start/stop the watcher and trigger a sync.
    private func reconfigure() {
        guard settings.isEnabled, settings.hasSelection else {
            stop()
            return
        }
        // Sync is on and folders are chosen, but the library may still be
        // unreadable. Log *why* rather than silently bailing — a TCC denial
        // is the one failure that otherwise leaves no trace in the logs at
        // all (issue #45).
        switch library.availability {
        case .available:
            break
        case .databaseMissing:
            log.notice("VoiceMemos sync is enabled but no library was found at \(self.library.databaseDisplayPath, privacy: .public) — nothing to sync (iCloud sync off, or no recordings yet).")
            stop()
            return
        case .accessDenied(let reason):
            log.error("VoiceMemos sync is enabled but macOS denied access to \(self.library.databaseDisplayPath, privacy: .public) (\(reason, privacy: .public)). Grant access to the Voice Memos folder from Settings → Voice Memos.")
            lastError = VoiceMemosLibrary.LibraryError.accessDenied(reason).localizedDescription
            stop()
            return
        }
        startWatcherIfNeeded()
        requestSync()
    }

    private func startWatcherIfNeeded() {
        guard watcher == nil else { return }
        let watcher = DirectoryWatcher(path: library.recordingsDirectory.path) { [weak self] in
            // FSEvents fires on a background queue; hop to the main actor.
            Task { @MainActor in self?.requestSync() }
        }
        watcher.start()
        self.watcher = watcher
        log.log("VoiceMemos watcher started on \(self.library.recordingsDirectoryDisplayPath, privacy: .public)")
    }

    /// Public entry point for the "Rescan now" button in Settings.
    func rescan() { requestSync() }

    /// Run a sync, coalescing requests so two never overlap.
    private func requestSync() {
        // Guard on `scanInFlight` (set synchronously at the top of `sync()`),
        // NOT the published `isSyncing` — the latter now only tracks visible
        // import work, so an idle scan leaves it false and two requests would
        // otherwise both spawn overlapping syncs.
        guard !scanInFlight else {
            pendingResync = true
            return
        }
        Task { await sync() }
    }

    private func sync() async {
        guard settings.isEnabled, settings.hasSelection else { return }
        // Re-check on entry: `requestSync`'s guard runs when the request is
        // made, but the flag only flips once this Task actually starts. Two
        // requests landing in the same main-actor drain (e.g. "Rescan now" +
        // an FSEvents hop) both saw false and spawned overlapping syncs — each
        // snapshots `alreadyImported` before the other's `store.add` lands, so
        // the same memo imported (and transcribed) twice. `scanInFlight` is set
        // synchronously below before the first `await`, closing that window.
        guard !scanInFlight else {
            pendingResync = true
            return
        }
        scanInFlight = true
        defer {
            scanInFlight = false
            // A folder change / FSEvents burst that arrived mid-sync set
            // `pendingResync`; kick the next pass now that the flag is clear
            // (doing this before clearing it would just re-set the flag and
            // the second pass would never run).
            if pendingResync {
                pendingResync = false
                requestSync()
            }
        }

        let folderUUIDs = settings.selectedFolderUUIDs
        let includeUnfiled = settings.includeUnfiled
        let startDate = settings.startDate

        // Read the (private, WAL-mode) DB off the main actor.
        let lib = library
        let memos: [VoiceMemosLibrary.Memo]
        do {
            memos = try await Task.detached(priority: .utility) {
                try lib.recordings(folderUUIDs: folderUUIDs, includeUnfiled: includeUnfiled)
            }.value
        } catch {
            setError(error.localizedDescription)
            log.error("VoiceMemos sync failed reading DB: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Live imports + tombstones of imports the user permanently
        // deleted — without the tombstones, deleting an imported memo in
        // Mila didn't stick (the source memo still exists in the Voice
        // Memos folder and re-imported on the next sync).
        let alreadyImported = Set(store.recordings.compactMap { $0.voiceMemoUniqueID })
            .union(store.voiceMemoTombstones)
        let fm = FileManager.default
        let plan = Self.plan(memos: memos,
                             alreadyImported: alreadyImported,
                             startDate: startDate,
                             minDuration: VoiceMemosSettings.minDurationSeconds,
                             fileExists: { fm.fileExists(atPath: $0.path) })

        // Nothing to import: publish the (stable) summary WITHOUT ever flipping
        // `isSyncing`. This is the fix for the "Last synced" flicker (issue
        // #57) — the FSEvents watcher fires ~once/second as voicememod touches
        // the WAL, and every one of those idle rescans used to flash the
        // spinner and re-stamp the timestamp. `publishOutcome` also skips any
        // no-op writes, so an idle rescan leaves the status line untouched.
        guard plan.hasVisibleWork else {
            publishOutcome(summary: plan.summary, imported: 0)
            return
        }

        // Real work — surface the spinner only for the actual import loop.
        isSyncing = true
        defer { isSyncing = false }

        var summary = plan.summary
        for memo in plan.toImport {
            do {
                let recording = try await FileTranscriber.importFile(
                    at: memo.fileURL,
                    into: store,
                    language: languageSettings.current,
                    source: .voiceMemo,
                    title: memo.title,
                    createdAt: memo.date,
                    voiceMemoUniqueID: memo.uniqueID,
                    // Record the origin folder so "un-select removes its
                    // recordings" (issue #57) can find them later. Unfiled
                    // memos carry the sentinel so they stay distinct from a
                    // legacy import whose origin was never stored.
                    voiceMemoFolderUUID: memo.folderUUID ?? Recording.voiceMemoUnfiledFolderID,
                    folder: Self.syncedFolderName
                )
                transcription.enqueue(recording)
                summary.imported += 1
            } catch {
                summary.failedImport += 1
                log.error("VoiceMemos import failed for \(memo.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        publishOutcome(summary: summary, imported: summary.imported)
        log.log("VoiceMemos sync: imported \(summary.imported), failed=\(summary.failedImport) older=\(summary.skippedOlder) short=\(summary.skippedShort) composition=\(summary.skippedComposition) missing=\(summary.skippedMissing)")
    }

    /// Publish a scan's results, mutating only the `@Published` state that
    /// actually changed. An idle rescan that imports nothing and finds the same
    /// held-back set as last time leaves every published property untouched, so
    /// the status line doesn't re-render — the crux of the anti-flicker fix
    /// (issue #57). Clearing a stale error only happens on a successful scan.
    private func publishOutcome(summary: SyncSummary, imported: Int) {
        if lastError != nil { lastError = nil }
        if imported > 0 {
            lastImportedCount = imported
            totalImported += imported
        }
        if summary != lastSummary { lastSummary = summary }
        // Bump the timestamp on real imports, and once on the first successful
        // scan so the user still gets an initial "Last synced …". Idle rescans
        // leave it alone, so it reads as a steady last-activity time rather
        // than a once-a-second churn.
        if imported > 0 || lastSyncDate == nil { lastSyncDate = Date() }
    }

    /// Set `lastError` only when it changes, so a failure that recurs on every
    /// idle rescan (e.g. a transient DB read error) doesn't re-render the
    /// status line each time.
    private func setError(_ message: String?) {
        if lastError != message { lastError = message }
    }
}
