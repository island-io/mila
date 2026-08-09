import Foundation
import Combine
import MilaKit

/// Opt-in for the bundled `mila-mcp` helper, which lets an MCP client
/// (Claude Code, Claude Desktop) read this Mac's transcriptions.
///
/// **Off by default, and it stays off until the user says otherwise.**
///
/// Two places hold the state, deliberately:
///
///   * `UserDefaults` (`mcp.enabled`) is what the UI binds to.
///   * `mcp-access.json` in the app-support root is what the helper reads.
///     The helper is a separate process and cannot see this app's defaults
///     domain reliably, so the app mirrors the flag into a file the helper
///     can check. `MCPAccessGate` fails closed on a missing or unreadable
///     file, so a mirror that never got written reads as "off".
///
/// The mirror is rewritten on every launch as well as on every change, so a
/// user who deletes the file, or upgrades from a build that predates it,
/// converges to whatever the UI says rather than to a stale value.
@MainActor
final class MCPAccessSettings: ObservableObject {

    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Keys.enabled)
            mirrorToDisk()
        }
    }

    /// Surfaced in the UI when the mirror can't be written — otherwise the
    /// toggle would claim access is on while the helper still refuses.
    @Published private(set) var mirrorError: String?

    private let defaults: UserDefaults
    private let root: URL

    enum Keys {
        static let enabled = "mcp.enabled"
    }

    init(defaults: UserDefaults = .standard,
         root: URL = StoreLocationPointer.defaultRoot()) {
        self.defaults = defaults
        self.root = root
        // No `object(forKey:)` dance: absent means false, which is the
        // default we want. Opt-in features shouldn't need a first-launch
        // special case.
        self.enabled = defaults.bool(forKey: Keys.enabled)
        mirrorToDisk()
    }

    private func mirrorToDisk() {
        do {
            try MCPAccessGate.set(enabled, root: root)
            mirrorError = nil
        } catch {
            mirrorError = error.localizedDescription
        }
    }
}
