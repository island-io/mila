import Foundation
import Combine
import OSLog

private let voiceMemosSettingsLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                           category: "VoiceMemosSettings")

/// User settings for iPhone Voice Memos folder integration. Persists which
/// Voice Memos folders Mila watches + auto-transcribes. Follows the same
/// shape as `DiarizationSettings`: `@Published` properties that write through
/// to namespaced `UserDefaults` keys, with an injectable `defaults` suite so
/// tests stay isolated from the user's real preferences.
///
/// Folders are keyed by their stable `ZFOLDER.ZUUID` (not their display name,
/// which the user can rename). The unfiled bucket — recordings with no folder,
/// usually the bulk of a library — is tracked by a separate flag.
@MainActor
final class VoiceMemosSettings: ObservableObject {

    /// Master switch. Off by default: Voice Memos sync reads another app's
    /// data and kicks off bulk transcription, so it's strictly opt-in.
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            // Turning sync on starts the cutoff at today so a large existing
            // library doesn't backfill years of memos into the queue. The user
            // moves the date earlier in Settings to pull older recordings in.
            if isEnabled, oldValue == false {
                startDate = Calendar.current.startOfDay(for: Date())
            }
        }
    }

    /// `ZUUID`s of the Voice Memos folders the user chose to watch.
    @Published var selectedFolderUUIDs: Set<String> {
        didSet {
            defaults.set(Array(selectedFolderUUIDs).sorted(), forKey: Keys.folderUUIDs)
        }
    }

    /// Whether to also watch the unfiled bucket (`ZFOLDER IS NULL`).
    @Published var includeUnfiled: Bool {
        didSet { defaults.set(includeUnfiled, forKey: Keys.includeUnfiled) }
    }

    /// Only import memos recorded on or after this date. Older memos are
    /// skipped so enabling sync on a large existing library doesn't flood the
    /// queue with years of backfill. Defaults to the start of today (set when
    /// sync is turned on); the always-visible picker in Settings lets the user
    /// move it earlier to backfill retroactively. Persisted as a plist `Date`.
    @Published var startDate: Date {
        didSet { defaults.set(startDate, forKey: Keys.startDate) }
    }

    /// The Voice Memos Recordings folder the user granted Mila access to,
    /// resolved from a persisted security-scoped bookmark. `nil` until the
    /// user grants it (or if the grant was lost). Reading another app's
    /// group container needs an explicit grant; this scoped, single-folder
    /// grant replaces the old Full Disk Access requirement. Mirrors the
    /// bookmark pattern in `RecordingStorageSettings`.
    @Published private(set) var grantedFolderURL: URL?

    /// The URL we currently hold `startAccessingSecurityScopedResource` on,
    /// paired with a `stop` before re-resolving. Unsandboxed builds don't
    /// strictly need this, but it's the correct pattern (and sandbox-ready).
    private var accessingURL: URL?

    private let defaults: UserDefaults

    private enum Keys {
        static let enabled = "voiceMemos.enabled"
        static let folderUUIDs = "voiceMemos.folderUUIDs"
        static let includeUnfiled = "voiceMemos.includeUnfiled"
        static let startDate = "voiceMemos.startDate"
        static let folderBookmark = "voiceMemos.folderBookmark"
    }

    /// The standard on-disk location of the synced Voice Memos library —
    /// what the "Grant Access" open panel points at so the user only has to
    /// confirm, not navigate into hidden `~/Library`.
    static var suggestedFolder: URL { VoiceMemosLibrary.defaultRecordingsDirectory }

    /// Skip accidental sub-`minDurationSeconds` taps during bulk import. Voice
    /// Memos libraries are full of 1–2s pocket recordings; transcribing them
    /// is pure noise. Not user-configurable — a sensible fixed floor.
    static let minDurationSeconds: Double = 3.0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Keys.enabled)
        let stored = defaults.stringArray(forKey: Keys.folderUUIDs) ?? []
        self.selectedFolderUUIDs = Set(stored)
        self.includeUnfiled = defaults.bool(forKey: Keys.includeUnfiled)
        if let stored = defaults.object(forKey: Keys.startDate) as? Date {
            self.startDate = stored
        } else {
            // Pin to the start of today on first run so the value doesn't
            // drift forward each launch — an unpinned "today" default would
            // keep moving the cutoff and silently hold back yesterday's memos.
            let today = Calendar.current.startOfDay(for: Date())
            self.startDate = today
            defaults.set(today, forKey: Keys.startDate)
        }
        resolveFolderAccess()
    }

    // MARK: - Scoped folder access (replaces Full Disk Access)

    /// True once Mila holds a working grant to the Voice Memos folder.
    var hasFolderAccess: Bool { grantedFolderURL != nil }

    /// Resolve the persisted bookmark and start accessing it. Idempotent —
    /// safe to call again after `grantFolder`. Mirrors
    /// `RecordingStorageSettings.resolveAndStartAccessing`.
    func resolveFolderAccess() {
        if let url = accessingURL {
            url.stopAccessingSecurityScopedResource()
            accessingURL = nil
        }
        grantedFolderURL = nil

        guard let data = defaults.data(forKey: Keys.folderBookmark) else { return }
        var isStale = false
        let resolved: URL
        do {
            resolved = try URL(resolvingBookmarkData: data,
                               options: [.withSecurityScope],
                               relativeTo: nil,
                               bookmarkDataIsStale: &isStale)
        } catch {
            // Unreadable blob — drop it so we don't fail on every launch.
            //
            // The bookmark is the folder grant the user made in the open panel
            // (PR #73 replaced Full Disk Access with this), so the error text
            // names a path they picked. Domain + code stay public — they say
            // whether the volume vanished or the blob is corrupt.
            // (Issue #213.)
            let ns = error as NSError
            voiceMemosSettingsLog.error("""
                failed to resolve folder bookmark \
                [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)]: \
                \(error.localizedDescription, privacy: .private)
                """)
            defaults.removeObject(forKey: Keys.folderBookmark)
            return
        }
        if isStale {
            if let refreshed = try? resolved.bookmarkData(options: [.withSecurityScope],
                                                          includingResourceValuesForKeys: nil,
                                                          relativeTo: nil) {
                defaults.set(refreshed, forKey: Keys.folderBookmark)
            } else {
                defaults.removeObject(forKey: Keys.folderBookmark)
                return
            }
        }
        let started = resolved.startAccessingSecurityScopedResource()
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir)
        if !exists || !isDir.boolValue {
            if started { resolved.stopAccessingSecurityScopedResource() }
            defaults.removeObject(forKey: Keys.folderBookmark)
            return
        }
        accessingURL = resolved
        grantedFolderURL = resolved
    }

    /// Persist a freshly-picked folder (from the "Grant Access" open panel)
    /// as a security-scoped bookmark and start accessing it. Returns true on
    /// success. Mirrors `RecordingStorageSettings.setDirectory`.
    @discardableResult
    func grantFolder(_ url: URL) -> Bool {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            defaults.set(data, forKey: Keys.folderBookmark)
            resolveFolderAccess()
            return grantedFolderURL != nil
        } catch {
            let ns = error as NSError
            voiceMemosSettingsLog.error("""
                failed to mint folder bookmark for \(url.path, privacy: .private) \
                [\(ns.domain, privacy: .public) \(ns.code, privacy: .public)]: \
                \(error.localizedDescription, privacy: .private)
                """)
            return false
        }
    }

    /// True when the user has actually picked something to watch — gates the
    /// importer so enabling the feature without choosing a folder is a no-op
    /// rather than silently importing nothing (or everything).
    var hasSelection: Bool {
        !selectedFolderUUIDs.isEmpty || includeUnfiled
    }

    /// Convenience toggle used by the folder multiselect in Settings.
    func setFolder(_ uuid: String, selected: Bool) {
        if selected {
            selectedFolderUUIDs.insert(uuid)
        } else {
            selectedFolderUUIDs.remove(uuid)
        }
    }
}
