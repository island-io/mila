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
///
/// ## Consent is necessary but not sufficient
///
/// What gets mirrored is `enabled && storeIsDiscoverable()` — the user's
/// consent AND a readiness check that mila-mcp would land on the store this
/// app is actually using. Without the second half, a failed
/// `store-location.json` write after a relocation leaves the helper reading
/// the OLD store: it answers, it sounds authoritative, and every answer is
/// from a store that stopped updating at the moment of relocation. There is
/// no version of that which beats refusing.
///
/// The readiness half is late-bound by `MilaApp` (the store is constructed
/// first) and re-consulted on every mirror, so it can never latch: it is
/// recomputed, not remembered.
@MainActor
final class MCPAccessSettings: ObservableObject {

    @Published var enabled: Bool {
        didSet {
            // Skipped only while `mirrorToDisk` is putting the toggle back
            // after a revocation it could not carry out — that path has
            // already written defaults and must not recurse.
            guard !isReconcilingEnabled else { return }
            defaults.set(enabled, forKey: Keys.enabled)
            mirrorToDisk()
        }
    }

    /// Surfaced in the UI when the mirror can't be written — otherwise the
    /// toggle would claim access is on while the helper still refuses.
    @Published private(set) var mirrorError: String?

    /// Set when consent is on but the store isn't discoverable, so the UI can
    /// explain a refusal the toggle's own state can't account for. A separate
    /// channel from `mirrorError`: that one means "we couldn't save your
    /// preference", this one means "we saved it and are still refusing".
    @Published private(set) var storeUnreachable: Bool = false

    /// Set when a revocation could not be carried out — the gate file could
    /// be neither overwritten nor deleted, so it is still granting access.
    /// The toggle is forced back ON in that case: an off switch that hasn't
    /// actually turned anything off is the one state this UI must never show.
    @Published private(set) var revocationFailed: Bool = false

    private var isReconcilingEnabled = false

    /// Where the mirror lives, for the "check that this is writable" message
    /// a failed revocation shows. Exposed here so the view doesn't have to
    /// know the on-disk layout.
    var gateFilePath: String { MCPAccessGate.url(root: root).path }

    private let defaults: UserDefaults
    private let root: URL

    /// Late-bound by `MilaApp` to the recording store's
    /// `storeLocationIsDiscoverable`. Defaults to "reachable" so the
    /// dictation-only setup and tests that don't wire a store behave exactly
    /// as they did before this check existed.
    var storeIsDiscoverable: () -> Bool = { true }

    enum Keys {
        static let enabled = "mcp.enabled"
    }

    init(defaults: UserDefaults = .standard,
         root: URL = StoreLocationPointer.defaultRoot(),
         storeIsDiscoverable: @escaping () -> Bool = { true }) {
        self.defaults = defaults
        self.root = root
        self.storeIsDiscoverable = storeIsDiscoverable
        // No `object(forKey:)` dance: absent means false, which is the
        // default we want. Opt-in features shouldn't need a first-launch
        // special case.
        self.enabled = defaults.bool(forKey: Keys.enabled)
        mirrorToDisk()
    }

    /// Re-evaluate and rewrite the mirror. Called by `MilaApp` when the
    /// store's discoverability changes — a mid-session relocation can flip it
    /// either way, and revoking (or restoring) access must not wait for a
    /// relaunch or for the user to touch the toggle.
    func refreshMirror() {
        mirrorToDisk()
    }

    private func mirrorToDisk() {
        let reachable = storeIsDiscoverable()
        let desired = enabled && reachable
        do {
            try MCPAccessGate.set(desired, root: root)
            mirrorError = nil
            revocationFailed = false
        } catch {
            mirrorError = error.localizedDescription
            // `MCPAccessGate.set(false, …)` only throws when it could neither
            // overwrite nor delete the file — i.e. access is STILL granted.
            // Failing to publish `true` is harmless by comparison (the gate
            // keeps denying), so only the deny direction escalates here.
            if !desired {
                revocationFailed = true
                if !enabled {
                    // The user turned it off and we couldn't make that true.
                    // Put the toggle back rather than let it claim otherwise.
                    isReconcilingEnabled = true
                    enabled = true
                    isReconcilingEnabled = false
                    defaults.set(true, forKey: Keys.enabled)
                }
            } else {
                revocationFailed = false
            }
        }
        // After any reconciliation above, so it reflects the toggle the user
        // is actually looking at.
        storeUnreachable = enabled && !reachable
    }
}
