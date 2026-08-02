import SwiftUI
import AppKit

/// Obsidian vault section, embedded in the Storage settings tab. Lets the user
/// route finished recordings into an Obsidian vault as Markdown notes (summary
/// + action items, transcript fallback), and optionally commit + push the vault
/// git repo after each write.
///
/// The vault folder is persisted via a security-scoped bookmark; see
/// `ObsidianVaultSettings` for the resolution / fallback rules. Notes are
/// written after the AI summary lands (falling back to the transcript when
/// summaries are off), so nothing here blocks recording.
///
/// **Visibility contract.** The feature is opt-in and adds no affordance
/// anywhere else in the app — no toolbar item, no context-menu entry, no
/// badge. On a fresh install the *only* thing it puts on screen is the single
/// toggle below, presented as one more card in Settings ▸ Storage rather than
/// a titled section of its own. Everything else here — the vault picker, the
/// git options, the backfill button, the error/stale notices — is rendered
/// only once `settings.enabled` is true, and the backfill button additionally
/// requires a chosen vault. Keep it that way.
struct ObsidianSettingsSection: View {
    @EnvironmentObject private var settings: ObsidianVaultSettings
    @EnvironmentObject private var store: RecordingStore
    @EnvironmentObject private var exporter: ObsidianExporter

    @State private var lastError: String?
    @State private var backfillResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            enableCard
            if settings.enabled {
                vaultCard
                gitCard
                if settings.vaultURL != nil {
                    backfillCard
                }
                if settings.lastResolutionWasStale {
                    staleBookmarkNotice
                }
                if let lastError {
                    Text(lastError)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The whole feature's footprint when it's off: one toggle and one line of
    /// caption, in the same card shape the rest of the Storage tab uses.
    private var enableCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "text.book.closed.fill")
                    .foregroundStyle(.tint)
                Toggle("Save transcripts to an Obsidian vault", isOn: $settings.enabled)
                    .accessibilityIdentifier("obsidian.enabled.toggle")
                Spacer()
            }
            if settings.enabled {
                Text("When a recording finishes, Mila writes a Markdown note into your vault — the AI summary plus any action items, falling back to the transcript when summaries are off. Notes are written after the summary lands, so this never blocks recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.vaultURL == nil {
                    Text("Pick a vault folder below to start filing notes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Off. Turn this on to file each finished recording into an Obsidian vault as a Markdown note.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var vaultCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.vaultURL.map(displayPath) ?? "No vault chosen")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(settings.vaultURL == nil ? "Not set" : "Vault folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                Button("Choose…") { chooseFolder() }
                    .accessibilityIdentifier("obsidian.chooseFolder.button")
                if settings.vaultURL != nil {
                    Button("Reveal in Finder") { revealInFinder() }
                }
                Spacer()
                Button("Clear") { settings.clearVault() }
                    .disabled(settings.vaultURL == nil)
                    .accessibilityIdentifier("obsidian.clear.button")
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    TextField("Subfolder in vault (blank = vault root)", text: $settings.subfolder)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("obsidian.subfolder.field")
                    Button("Browse…") { browseSubfolder() }
                        .disabled(settings.vaultURL == nil)
                        .help("Pick a folder inside the vault")
                        .accessibilityIdentifier("obsidian.subfolderBrowse.button")
                }
                Text("Notes are written into this folder inside the vault (created if needed). One note per recording, named by date and title; re-transcribing overwrites the same note.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var gitCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Commit & push to git after writing", isOn: $settings.gitSyncEnabled)
                .accessibilityIdentifier("obsidian.gitSync.toggle")
            if settings.gitSyncEnabled {
                HStack(spacing: 8) {
                    Text("Branch")
                        .font(.callout)
                    TextField("main", text: $settings.gitBranch)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .accessibilityIdentifier("obsidian.gitBranch.field")
                }
                Text("After each note, Mila runs git add + commit, pulls with rebase, and pushes to this branch. Your vault must already be a git repo with credentials configured (SSH key or credential helper) — Mila runs git non-interactively and won't prompt for passwords.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let syncError = settings.lastSyncError {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Last sync failed: \(syncError)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var backfillCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Existing transcripts")
                .font(.callout.weight(.semibold))
            Text("Obsidian was set up after some recordings already existed. Sync them into the vault now — each is filed under its Mila folder (created if needed) and existing notes are overwritten in place.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Sync existing transcripts") { syncExisting() }
                    .accessibilityIdentifier("obsidian.backfill.button")
                if let backfillResult {
                    Text(backfillResult)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var staleBookmarkNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("The vault folder you chose was moved or renamed. Mila refreshed the saved reference — if notes stop appearing, pick the folder again.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func displayPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let path = url.path
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func chooseFolder() {
        lastError = nil
        let panel = NSOpenPanel()
        panel.title = "Choose your Obsidian vault folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.vaultURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard settings.setVault(url) else {
            lastError = "Couldn't save that folder. Try a different location (some network/cloud volumes can't be bookmarked)."
            return
        }
    }

    private func revealInFinder() {
        guard let url = settings.vaultURL else { return }
        // Open the vault directory itself, matching `StorageSettingsTab`:
        // `activateFileViewerSelecting([url])` highlights the folder inside its
        // parent, but for a folder target the user wants to step _into_ it.
        NSWorkspace.shared.open(url)
    }

    /// Backfill: write every non-trashed recording that has content into the
    /// vault. `exportAll` skips empty ones and kicks a single git sync.
    private func syncExisting() {
        lastError = nil
        let recordings = store.recordings.filter { !$0.isTrashed }
        let count = exporter.exportAll(recordings)
        backfillResult = count == 0
            ? "Nothing to sync."
            : "Synced \(count) note\(count == 1 ? "" : "s")."
    }

    /// Pick the destination subfolder with a folder panel constrained to the
    /// vault. Stores the path RELATIVE to the vault (blank when the vault root
    /// is chosen); rejects a folder outside the vault.
    private func browseSubfolder() {
        guard let vault = settings.vaultURL else { return }
        lastError = nil
        let panel = NSOpenPanel()
        panel.title = "Choose a subfolder inside the vault"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.destinationDirectory ?? vault
        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        // Resolve symlinks on both sides so an NSOpenPanel path (which can be
        // /private-prefixed) compares cleanly against the bookmark-resolved
        // vault URL.
        let vaultPath = vault.resolvingSymlinksInPath().path
        let chosenPath = chosen.resolvingSymlinksInPath().path
        if chosenPath == vaultPath {
            settings.subfolder = ""
            return
        }
        let prefix = vaultPath.hasSuffix("/") ? vaultPath : vaultPath + "/"
        guard chosenPath.hasPrefix(prefix) else {
            lastError = "Choose a folder inside the vault (\(vault.lastPathComponent))."
            return
        }
        settings.subfolder = String(chosenPath.dropFirst(prefix.count))
    }
}
