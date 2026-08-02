import SwiftUI
import AppKit

/// Settings → Voice Memos. Lets the user sync recordings made on their iPhone
/// (synced to this Mac via iCloud) into Mila, picking which Voice Memos
/// folders to watch. New recordings in those folders are imported and
/// transcribed automatically; see `VoiceMemosImporter`.
struct VoiceMemosSettingsTab: View {
    @EnvironmentObject private var settings: VoiceMemosSettings
    @EnvironmentObject private var importer: VoiceMemosImporter
    @EnvironmentObject private var store: RecordingStore

    @State private var folders: [VoiceMemosLibrary.Folder] = []
    @State private var unfiledCount = 0
    @State private var loadError: String?
    @State private var isLoading = false

    /// Folder ids (a `ZFOLDER.ZUUID`, or `unfiledPreviewID` for the unfiled
    /// bucket) the user expanded to preview contents (issue #57, part 2).
    @State private var expandedFolderIDs: Set<String> = []
    /// Cached preview memos per folder id — the first `previewLimit` titles,
    /// loaded lazily on expand so the user can review a folder WITHOUT syncing.
    @State private var previews: [String: [VoiceMemosLibrary.Memo]] = [:]
    /// Folder ids with a preview load in flight (drives the row's spinner).
    @State private var loadingPreviews: Set<String> = []
    /// Folder ids whose last preview load FAILED. Tracked separately from
    /// `previews` so a read error isn't cached as an empty folder (which would
    /// suppress retries and show a false "No recordings"); re-expanding retries.
    @State private var previewErrors: Set<String> = []
    /// Bumped on every `loadFolders` (rescan / settings change). Async folder
    /// and preview loads capture the current value and drop their results if a
    /// newer load has started since, so a stale `Task` can't clobber fresh state.
    @State private var loadGeneration = 0
    /// Set when de-selecting a folder that still has imported recordings, to
    /// drive the "remove its recordings?" confirmation (issue #57, part 1).
    @State private var pendingCleanup: PendingCleanup?

    /// Stable key for the unfiled bucket in the preview/expansion dictionaries
    /// (it has no real folder UUID). Reuses the same sentinel the importer
    /// stamps onto unfiled imports so the two never disagree.
    private var unfiledPreviewID: String { Recording.voiceMemoUnfiledFolderID }

    /// Cap on how many memo titles a preview loads/shows — enough to review a
    /// folder without reading/rendering thousands of rows.
    private let previewLimit = 50

    private struct PendingCleanup: Identifiable {
        let folderID: String
        let name: String
        let count: Int
        var id: String { folderID }
    }

    /// Reader over the folder the user granted (falling back to the standard
    /// location, which is what a legacy Full-Disk-Access user already sees).
    private var library: VoiceMemosLibrary {
        VoiceMemosLibrary(recordingsDirectory: settings.grantedFolderURL
                          ?? VoiceMemosLibrary.defaultRecordingsDirectory)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            // Always render the master toggle — otherwise a user who enabled
            // sync and then lost the library (iCloud off, etc.) would have no
            // control left to turn the integration back off.
            Toggle("Sync recordings from iPhone Voice Memos", isOn: $settings.isEnabled)
                .toggleStyle(.switch)

            if settings.isEnabled {
                switch library.availability {
                case .available:
                    folderPicker
                    startDatePicker
                    statusFooter
                case .databaseMissing:
                    // We can read the folder (grant or legacy FDA in place)
                    // but there's no library there — iCloud sync off, or the
                    // user granted the wrong folder.
                    unavailableNotice
                case .accessDenied:
                    grantAccessNotice
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(settings.isEnabled)-\(settings.grantedFolderURL?.path ?? "")") {
            if settings.isEnabled { await loadFolders() }
        }
        .confirmationDialog(
            "Remove imported recordings?",
            isPresented: Binding(
                get: { pendingCleanup != nil },
                set: { if !$0 { pendingCleanup = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingCleanup
        ) { cleanup in
            Button("Move \(cleanup.count) to Recently Deleted", role: .destructive) {
                store.softDeleteVoiceMemos(fromFolderID: cleanup.folderID)
                pendingCleanup = nil
            }
            Button("Keep Recordings", role: .cancel) { pendingCleanup = nil }
        } message: { cleanup in
            Text("Move the \(cleanup.count) recording\(cleanup.count == 1 ? "" : "s") imported from “\(cleanup.name)” to Recently Deleted? "
                 + "You can restore them there, and re-syncing this folder later won't create duplicates.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Voice Memos")
                .font(.title2).bold()
            Text("Automatically transcribe recordings you make on your iPhone. "
                 + "Mila watches the Voice Memos folders you choose and imports new recordings as they sync over iCloud.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var unavailableNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "iphone.slash")
                .foregroundStyle(.secondary)
            Text("No Voice Memos library was found on this Mac. Make sure Voice Memos iCloud sync "
                 + "is turned on for both your iPhone and this Mac, then reopen this tab.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    /// Shown until Mila holds a scoped grant to the Voice Memos folder. Mila
    /// is not sandboxed, so reading another app's group container needs the
    /// user's consent — but a one-folder grant is all it takes, no Full Disk
    /// Access. The panel is pre-pointed at the folder so the user just
    /// confirms rather than navigating hidden `~/Library`.
    private var grantAccessNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text("Mila needs your permission to read the Voice Memos folder. Click below "
                     + "and confirm — Mila gets access to just that one folder, not your whole disk.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Grant Access…") { grantAccess() }
                // A failed grant leaves availability at `.accessDenied`, so this
                // card (not `folderPicker`) stays on screen — surface the error
                // here or the user gets no feedback.
                if let loadError {
                    Text(loadError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }

    /// Run the folder-grant open panel, pre-pointed at the standard Voice
    /// Memos location, and persist the resulting security-scoped bookmark.
    private func grantAccess() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = VoiceMemosSettings.suggestedFolder
        panel.message = "Grant Mila access to your iPhone Voice Memos recordings folder."
        panel.prompt = "Grant Access"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if settings.grantFolder(url) {
            Task { await loadFolders() }
            importer.rescan()
        } else {
            loadError = "Couldn't save access to that folder. Please try again."
        }
    }

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Folders to watch")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await loadFolders() }
                    importer.rescan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading || importer.isSyncing)
            }

            if let loadError {
                Text(loadError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            List {
                folderGroup(id: unfiledPreviewID,
                            name: "Unfiled",
                            count: unfiledCount,
                            systemImage: "tray",
                            isUnfiled: true)
                ForEach(folders) { folder in
                    folderGroup(id: folder.uuid,
                                name: folder.name,
                                count: folder.count,
                                systemImage: "folder",
                                isUnfiled: false)
                }
            }
            .frame(height: 220)
            .overlay {
                if folders.isEmpty && unfiledCount == 0 && !isLoading && loadError == nil {
                    Text("No recordings found.")
                        .foregroundStyle(.secondary)
                }
            }

            if !settings.hasSelection {
                Text("Choose at least one folder to start syncing. Tap the arrow to preview a folder's recordings before turning it on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One folder in the picker: a selection toggle with a leading disclosure
    /// arrow that expands an inline, non-importing preview of the folder's
    /// recordings (issue #57, part 2).
    @ViewBuilder
    private func folderGroup(id: String,
                             name: String,
                             count: Int,
                             systemImage: String,
                             isUnfiled: Bool) -> some View {
        HStack(spacing: 6) {
            Button {
                toggleExpand(id: id, isUnfiled: isUnfiled)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expandedFolderIDs.contains(id) ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // An empty folder has nothing to preview; keep the space so the
            // toggles stay aligned.
            .disabled(count == 0)
            .opacity(count == 0 ? 0 : 1)
            .help(expandedFolderIDs.contains(id) ? "Hide recordings" : "Preview recordings")

            Toggle(isOn: selectionBinding(folderID: id, isUnfiled: isUnfiled, displayName: name)) {
                folderRow(name: name, count: count, systemImage: systemImage)
            }
        }

        if expandedFolderIDs.contains(id) {
            previewRows(for: id, total: count)
        }
    }

    /// Inline preview rows shown under an expanded folder — a loading spinner,
    /// an empty note, or the memo titles + a "…and N more" overflow line.
    @ViewBuilder
    private func previewRows(for id: String, total: Int) -> some View {
        if loadingPreviews.contains(id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.leading, 26)
        } else if previewErrors.contains(id) {
            Text("Couldn't load recordings — collapse and expand to retry.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 26)
        } else if let memos = previews[id] {
            if memos.isEmpty {
                Text("No recordings in this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
            } else {
                ForEach(memos) { memo in
                    HStack {
                        Text(memo.title)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(memo.date, format: .dateTime.month().day().year())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 26)
                }
                if total > memos.count {
                    Text("…and \(total - memos.count) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 26)
                }
            }
        }
    }

    private func folderRow(name: String, count: Int, systemImage: String) -> some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(name)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Toggle a folder's inline preview, lazily loading its memo titles the
    /// first time it's expanded.
    private func toggleExpand(id: String, isUnfiled: Bool) {
        if expandedFolderIDs.contains(id) {
            expandedFolderIDs.remove(id)
        } else {
            expandedFolderIDs.insert(id)
            loadPreview(id: id, isUnfiled: isUnfiled)
        }
    }

    /// Read a folder's memo titles off the main actor and cache them. Reuses
    /// the read-only library reader — no import, no queueing.
    private func loadPreview(id: String, isUnfiled: Bool) {
        // Don't start a preview while a folder refresh is in flight — it would
        // capture the refresh's generation and cache a snapshot the refresh's
        // own end-of-load pass would then suppress. `loadFolders` re-loads
        // previews for expanded folders once the refresh finishes.
        guard !isLoading, previews[id] == nil, !loadingPreviews.contains(id) else { return }
        loadingPreviews.insert(id)
        previewErrors.remove(id)
        let lib = library
        let limit = previewLimit
        let gen = loadGeneration
        Task {
            let loaded: [VoiceMemosLibrary.Memo]?
            do {
                loaded = try await Task.detached(priority: .userInitiated) {
                    let memos = try lib.recordings(
                        folderUUIDs: isUnfiled ? [] : [id],
                        includeUnfiled: isUnfiled)
                    return Array(memos.sorted { $0.date > $1.date }.prefix(limit))
                }.value
            } catch {
                loaded = nil
            }
            // Drop stale results: a rescan/settings change started a newer load.
            guard gen == loadGeneration else { return }
            loadingPreviews.remove(id)
            if let loaded {
                previews[id] = loaded
            } else {
                // Don't cache the failure as an empty folder — flag it so the
                // row shows a retryable error instead of a false "No recordings".
                previewErrors.insert(id)
            }
        }
    }

    /// Retroactive start-date cutoff. Always visible; defaults to today when
    /// sync is turned on (see `VoiceMemosSettings`) so enabling on a large
    /// library doesn't backfill years of memos. The user moves the date
    /// earlier to pull in older recordings.
    private var startDatePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Transcribe memos recorded after")
                DatePicker(
                    "Start date",
                    selection: $settings.startDate,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
            }
            Text("Memos recorded before this date aren't imported. Move it earlier to backfill older recordings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if importer.isSyncing {
                    ProgressView().controlSize(.small)
                    Text("Syncing…").foregroundStyle(.secondary)
                } else if let error = importer.lastError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).foregroundStyle(.secondary)
                } else if let date = importer.lastSyncDate {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened)) — "
                         + "\(importer.totalImported) imported this session")
                        .foregroundStyle(.secondary)
                }
            }
            // Explain why the last scan imported less than the folder count —
            // otherwise "0 imported" with memos present looks broken (before
            // the start-date cutoff, not downloaded yet, failed to decode…).
            if !importer.isSyncing, importer.lastError == nil, let detail = lastScanDetail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One-line "why were some skipped" summary of the most recent scan, or
    /// nil when nothing was skipped.
    private var lastScanDetail: String? {
        let s = importer.lastSummary
        var parts: [String] = []
        if s.failedImport > 0 { parts.append("\(s.failedImport) failed to import") }
        if s.skippedOlder > 0 { parts.append("\(s.skippedOlder) before start date") }
        if s.skippedMissing > 0 { parts.append("\(s.skippedMissing) not downloaded from iCloud yet") }
        if s.skippedShort > 0 { parts.append("\(s.skippedShort) too short") }
        if s.skippedComposition > 0 { parts.append("\(s.skippedComposition) multi-take") }
        guard !parts.isEmpty else { return nil }
        return "Last scan held back " + parts.joined(separator: ", ") + "."
    }

    /// Selection toggle for a folder (or the unfiled bucket). Turning it OFF
    /// stops future imports immediately, then — if that folder already
    /// imported recordings — arms the cleanup confirmation so de-selecting can
    /// actually reverse the sync (issue #57, part 1).
    private func selectionBinding(folderID: String,
                                  isUnfiled: Bool,
                                  displayName: String) -> Binding<Bool> {
        Binding(
            get: {
                isUnfiled ? settings.includeUnfiled : settings.selectedFolderUUIDs.contains(folderID)
            },
            set: { newValue in
                if newValue {
                    if isUnfiled { settings.includeUnfiled = true }
                    else { settings.setFolder(folderID, selected: true) }
                    return
                }
                // De-selecting: stop future imports right away.
                if isUnfiled { settings.includeUnfiled = false }
                else { settings.setFolder(folderID, selected: false) }
                // Then offer to remove what this folder already imported. The
                // cleanup keys on the recorded origin (a real ZUUID, or the
                // unfiled sentinel), independent of this display name.
                let cleanupID = isUnfiled ? Recording.voiceMemoUnfiledFolderID : folderID
                let matches = store.voiceMemoRecordings(fromFolderID: cleanupID).count
                if matches > 0 {
                    pendingCleanup = PendingCleanup(folderID: cleanupID,
                                                    name: displayName,
                                                    count: matches)
                }
            }
        )
    }

    private func loadFolders() async {
        loadGeneration &+= 1
        let gen = loadGeneration
        isLoading = true
        loadError = nil
        // Drop cached previews so a rescan reflects the current library; keep
        // the user's expansion choices and re-load previews for what's open.
        // Also clear in-flight/error preview state so a rescan can re-load a
        // folder that was previously loading or had failed.
        previews.removeAll()
        loadingPreviews.removeAll()
        previewErrors.removeAll()
        let lib = library
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                (folders: try lib.folders(), unfiled: try lib.unfiledCount())
            }.value
            // A newer load started while this one was in flight — drop stale
            // results and let that newer load own `isLoading`.
            guard gen == loadGeneration else { return }
            folders = loaded.folders
            unfiledCount = loaded.unfiled
            // Clear `isLoading` BEFORE kicking off preview loads: `loadPreview`
            // refuses to start while a refresh is in flight (so a user expand
            // mid-refresh can't cache a snapshot the refresh would then suppress),
            // and this end-of-refresh pass is what loads previews for open folders.
            isLoading = false
            for id in expandedFolderIDs {
                loadPreview(id: id, isUnfiled: id == unfiledPreviewID)
            }
        } catch {
            guard gen == loadGeneration else { return }
            // Drop stale data so a failed refresh can't leave the user
            // interacting with folder choices that no longer reflect the DB.
            folders = []
            unfiledCount = 0
            loadError = error.localizedDescription
            isLoading = false
        }
    }
}
