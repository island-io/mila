import Foundation

/// The user's Application Support directory, resolved without ever crashing.
///
/// `FileManager.url(for:in:appropriateFor:create:)` throws when the directory
/// can't be created (read-only home, broken sandbox container, full disk), and
/// `try!` turned that into a launch-time crash with no way to recover.
/// `SpeakerProfileStore` already falls back to the temporary directory; this
/// gives the remaining call sites the same behaviour in one place.
enum AppSupportLocation {
    /// `nonisolated` so background callers (e.g. `DiarizationBootstrap`) can use it.
    nonisolated static func directory(
        fileManager: FileManager = .default,
        create: Bool = true
    ) -> URL {
        if let url = try? fileManager.url(for: .applicationSupportDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: nil,
                                          create: create) {
            return url
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }
}
