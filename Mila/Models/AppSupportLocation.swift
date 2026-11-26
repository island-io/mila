import Foundation
import OSLog

private let appSupportLog = Logger(subsystem: "io.island.whisper.IslandWhisper",
                                   category: "AppSupportLocation")

/// The user's Application Support directory, resolved without ever crashing.
///
/// `FileManager.url(for:in:appropriateFor:create:)` throws when the directory
/// can't be created (read-only home, broken sandbox container, full disk), and
/// `try!` turned that into a launch-time crash with no way to recover.
/// `RecordingStore` and `DiarizationBootstrap` used that `try!`; they now share
/// this lookup. It ends in the same temporary-directory fallback
/// `SpeakerProfileStore` uses.
enum AppSupportLocation {
    /// `nonisolated` so background callers (e.g. `DiarizationBootstrap`) can use it.
    nonisolated static func directory(
        fileManager: FileManager = .default,
        create: Bool = true
    ) -> URL {
        do {
            return try fileManager.url(for: .applicationSupportDirectory,
                                       in: .userDomainMask,
                                       appropriateFor: nil,
                                       create: create)
        } catch {
            // Logged because every write under the returned URL is a `try?`
            // at the callers: without this line a launch that can't save
            // anything leaves no trace. Domain + code only — Cocoa's message
            // quotes the path, and the path names the user's home folder.
            let ns = error as NSError
            appSupportLog.error("""
                Application Support lookup failed \
                (\(ns.domain, privacy: .public) \(ns.code, privacy: .public)); \
                using the search-path location without creating it
                """)
        }
        if let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return url
        }
        appSupportLog.error("Application Support has no search-path location; using the temporary directory")
        return fileManager.temporaryDirectory
    }
}
