import Foundation
import Combine

/// User-configurable Obsidian vault destination. When enabled, Mila writes a
/// Markdown note (summary + action items, with a transcript fallback) into the
/// chosen vault folder after every recording finishes — and, optionally,
/// commits + pushes the vault git repo.
///
/// Mirrors `RecordingStorageSettings`: the vault folder is persisted as a
/// **security-scoped bookmark** (not a raw path) so it survives moves/renames
/// and keeps working if/when the app is sandboxed. The
/// `com.apple.security.files.user-selected.read-write` entitlement is already
/// declared, so bookmark access is granted at pick time and held for the app's
/// lifetime.
@MainActor
final class ObsidianVaultSettings: ObservableObject {
    static let enabledKey = "obsidian.enabled"
    static let bookmarkKey = "obsidian.vaultBookmark"
    static let subfolderKey = "obsidian.subfolder"
    static let gitEnabledKey = "obsidian.git.enabled"
    static let gitBranchKey = "obsidian.git.branch"

    /// Default subfolder within the vault. Blank means "vault root".
    static let defaultSubfolder = "Transcripts"
    static let defaultBranch = "main"

    /// Master switch. Off by default — the feature is opt-in and the
    /// existing local-only experience is unchanged unless the user turns
    /// this on and picks a vault.
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
        }
    }

    /// Relative folder inside the vault that notes are written into (e.g.
    /// `Transcripts`). Blank = the vault root.
    @Published var subfolder: String {
        didSet {
            guard subfolder != oldValue else { return }
            defaults.set(subfolder, forKey: Self.subfolderKey)
        }
    }

    /// When on, each written note is committed and pushed to the vault's
    /// git remote (`add + commit -> pull --rebase -> push`). Requires the
    /// vault to be a working git repo with credentials pre-configured
    /// (SSH key / credential helper) — Mila runs git non-interactively.
    @Published var gitSyncEnabled: Bool {
        didSet {
            guard gitSyncEnabled != oldValue else { return }
            defaults.set(gitSyncEnabled, forKey: Self.gitEnabledKey)
        }
    }

    /// Branch the sync pushes to (default `main`).
    @Published var gitBranch: String {
        didSet {
            guard gitBranch != oldValue else { return }
            defaults.set(gitBranch, forKey: Self.gitBranchKey)
        }
    }

    /// Human-readable message from the last git sync, or nil when the last
    /// one succeeded / none has run. Surfaced in the Obsidian settings tab.
    /// Deliberately NOT persisted — a stale error across launches would be
    /// misleading.
    @Published var lastSyncError: String?

    /// The resolved vault folder, or nil when none is picked. Published so
    /// the settings UI re-renders on pick/clear.
    @Published private(set) var vaultURL: URL?

    /// Set when the persisted bookmark resolved stale (folder moved) so the
    /// UI can show a "refreshed the reference" badge.
    @Published private(set) var lastResolutionWasStale: Bool = false

    private let defaults: UserDefaults
    private var accessingURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        self.subfolder = defaults.string(forKey: Self.subfolderKey) ?? Self.defaultSubfolder
        self.gitSyncEnabled = defaults.bool(forKey: Self.gitEnabledKey)
        self.gitBranch = defaults.string(forKey: Self.gitBranchKey) ?? Self.defaultBranch
        resolveAndStartAccessing()
    }

    /// The directory notes are written into: the vault root plus the
    /// configured subfolder. nil when no vault is picked.
    var destinationDirectory: URL? {
        guard let vaultURL else { return nil }
        let clean = subfolder
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return clean.isEmpty ? vaultURL : vaultURL.appendingPathComponent(clean, isDirectory: true)
    }

    /// Resolve the persisted bookmark into a URL and start accessing it.
    /// Idempotent — safe to re-call after `setVault` / `clearVault`.
    private func resolveAndStartAccessing() {
        if let url = accessingURL {
            url.stopAccessingSecurityScopedResource()
            accessingURL = nil
        }
        vaultURL = nil
        lastResolutionWasStale = false

        guard let data = defaults.data(forKey: Self.bookmarkKey) else { return }
        var isStale = false
        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            print("ObsidianVaultSettings: failed to resolve bookmark: \(error)")
            defaults.removeObject(forKey: Self.bookmarkKey)
            return
        }
        if isStale {
            lastResolutionWasStale = true
            if let refreshed = try? resolved.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                defaults.set(refreshed, forKey: Self.bookmarkKey)
            } else {
                defaults.removeObject(forKey: Self.bookmarkKey)
                return
            }
        }
        let started = resolved.startAccessingSecurityScopedResource()
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            if started { resolved.stopAccessingSecurityScopedResource() }
            defaults.removeObject(forKey: Self.bookmarkKey)
            return
        }
        accessingURL = resolved
        vaultURL = resolved
    }

    /// Persist a freshly-picked vault folder. Returns true on success.
    @discardableResult
    func setVault(_ url: URL) -> Bool {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: Self.bookmarkKey)
            resolveAndStartAccessing()
            return vaultURL != nil
        } catch {
            print("ObsidianVaultSettings: failed to mint bookmark for \(url.path): \(error)")
            return false
        }
    }

    /// Forget the chosen vault.
    func clearVault() {
        defaults.removeObject(forKey: Self.bookmarkKey)
        resolveAndStartAccessing()
    }
}
