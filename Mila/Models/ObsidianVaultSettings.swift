import Foundation
import Combine

/// Filesystem-name safety for everything Mila writes into the vault.
///
/// Free of actor isolation so both the settings model and `ObsidianExporter`
/// share one implementation. Two of the three inputs are free text the user
/// typed (the vault subfolder field) or named elsewhere in the app (a Mila
/// folder name, a recording title), so all three go through here before they
/// become path components.
enum ObsidianPathSanitizer {
    /// Illegal / hostile in a macOS path component. `/` is the separator,
    /// the rest are either reserved on other platforms Obsidian vaults get
    /// synced to or invisible in a filename.
    private static let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        .union(.newlines)
        .union(.controlCharacters)

    /// Strip path-hostile characters, collapse whitespace, and cap the length
    /// so the result is a safe single-line name fragment.
    ///
    /// This does NOT guarantee a usable *component* on its own — the result
    /// may be empty, `.` or `..`. Callers that build a directory name must use
    /// `directoryComponent`; `ObsidianExporter.fileName` is safe because it
    /// always prefixes the date, so the fragment can never stand alone.
    ///
    /// `maxBytes` is a UTF-8 budget, not a character count: HFS+/APFS cap a
    /// component at 255 bytes, and a title of emoji or Hebrew hits that far
    /// sooner than 255 characters would suggest. 180 leaves comfortable room
    /// for the `yyyy-MM-dd ` prefix and the `.md` suffix.
    static func nameFragment(_ raw: String, maxBytes: Int = 180) -> String {
        let stripped = raw.components(separatedBy: invalid).joined(separator: " ")
        let collapsed = stripped
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        return truncated(collapsed, maxBytes: maxBytes)
    }

    /// A safe *directory* name: `nameFragment` plus the rules that stop a
    /// component escaping its parent or hiding itself. Leading dots are
    /// dropped, so `.`, `..` and `.hidden` collapse to `""`, `""` and
    /// `"hidden"` — callers treat an empty result as "use the parent".
    ///
    /// The leading run that gets dropped is dots **and the whitespace between
    /// them**, not dots alone. Stripping only dots left a whole family of
    /// traversal components intact:
    ///
    ///   * `". .."` — the dot-strip stopped at the space and `".."` survived.
    ///   * `"../.."` — `nameFragment` turns the `/` into a space first, so the
    ///     dot-strip saw `".. .."`, stopped at the space, and left `".."`.
    ///
    /// Either one resolved a note *above* the configured destination.
    static func directoryComponent(_ raw: String) -> String {
        var name = nameFragment(raw)
        while let first = name.first, first == "." || first == " " || first == "\t" {
            name.removeFirst()
        }
        name = name.trimmingCharacters(in: .whitespaces)
        // Belt and braces: whatever the rules above evolve into, a relative
        // reference must never leave this function.
        guard name != ".", name != ".." else { return "" }
        return name
    }

    /// Final containment guard: true when `candidate` resolves inside `root`.
    ///
    /// `directoryComponent` already makes a traversal component impossible, so
    /// this is defence in depth at the point of the actual write — a future
    /// change to the naming rules must not be able to turn into a file written
    /// outside the vault.
    ///
    /// Deliberately `standardized` (lexical `..`/`.` resolution) and not
    /// `standardizedFileURL`: the latter consults the filesystem and strips a
    /// `/private` prefix only when the path already exists, so it compares an
    /// existing vault against a not-yet-created destination inconsistently.
    static func isContained(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardized.path
        let path = candidate.standardized.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }

    /// Sanitize a user-typed vault-relative path (`Notes/Meetings`, and also
    /// `../../Desktop`) into one that cannot escape the vault: every component
    /// goes through `directoryComponent`, and components that sanitize to
    /// nothing (`.`, `..`, empty) are dropped.
    static func relativePath(_ raw: String) -> String {
        raw.split(separator: "/")
            .map { directoryComponent(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    /// Truncate on a UTF-8 byte budget without splitting a character.
    private static func truncated(_ value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var out = ""
        var used = 0
        for character in value {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            out.append(character)
            used += size
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

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
    ///
    /// `subfolder` is a free-text field, so it is sanitized per component
    /// rather than merely trimmed — a typed `../../Desktop` must resolve
    /// inside the vault, not outside it.
    var destinationDirectory: URL? {
        guard let vaultURL else { return nil }
        let clean = ObsidianPathSanitizer.relativePath(
            subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
        )
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
        // Only record a URL we actually started accessing, so the balancing
        // `stopAccessingSecurityScopedResource()` in the next resolve can never
        // be sent for an access that never began.
        accessingURL = started ? resolved : nil
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
