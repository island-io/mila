import Foundation

/// The consent gate for external MCP access. **Off unless the app says
/// otherwise**: absence of the file means disabled, so a fresh install, a
/// user who never opened the setting, and a user who turned it back off are
/// all the same state.
///
/// ## What this does and does not protect
///
/// It is deliberately *not* a security boundary, and shouldn't be described
/// as one. `mila-mcp` runs as the user, and so does everything else the user
/// runs — anything with the user's uid can already read
/// `~/Library/Application Support/Mila/` directly, with or without this file.
/// Routing reads through a socket or a localhost port wouldn't change that;
/// a `0600` socket is reachable by exactly the same principals as a `0600`
/// file.
///
/// What it does do is stop the realistic failure: an MCP client that is
/// configured and running — Claude Desktop, an editor agent — quietly
/// reading meeting transcripts and shipping them to a cloud model because
/// the tools happened to be there. That is an *accident* prevented by an
/// explicit opt-in, not an attack prevented by a permission check.
public struct MCPAccessGate: Codable, Equatable, Sendable {

    public var enabled: Bool
    public var updatedAt: Date

    public init(enabled: Bool, updatedAt: Date) {
        self.enabled = enabled
        self.updatedAt = updatedAt
    }

    public static let fileName = "mcp-access.json"

    /// Lives at the fixed default app-support root, beside
    /// `store-location.json` — *not* in a relocated recordings directory,
    /// so the helper can answer "am I allowed?" before resolving where the
    /// store lives.
    public static func url(root: URL = StoreLocationPointer.defaultRoot()) -> URL {
        root.appendingPathComponent(fileName)
    }

    /// Unreadable, absent, or malformed all mean disabled — the gate fails
    /// closed on anything it doesn't positively understand.
    public static func isEnabled(root: URL = StoreLocationPointer.defaultRoot()) -> Bool {
        guard let data = try? Data(contentsOf: url(root: root)) else { return false }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let gate = try? decoder.decode(MCPAccessGate.self, from: data) else { return false }
        return gate.enabled
    }

    /// Called by the app when the user flips the setting.
    ///
    /// ## Revoking has to fail closed
    ///
    /// The two directions are not symmetric, and treating them as one write
    /// is what made revocation fail OPEN (CodeRabbit on #183, CWE-359):
    ///
    ///   * Failing to publish **enabled** is safe. The file keeps whatever it
    ///     had, and every "anything I don't positively understand" case —
    ///     absent, unreadable, malformed — already denies. The worst outcome
    ///     is access the user asked for not arriving.
    ///   * Failing to publish **disabled** is not. The previous
    ///     `enabled: true` file survives the failed atomic write, so the
    ///     toggle reads off in the UI while a configured MCP client keeps
    ///     reading transcripts — indefinitely, and invisibly.
    ///
    /// So a failed revocation escalates to deleting the file, which denies by
    /// absence. `set(false, …)` throws only when access is *still* granted
    /// afterwards, which lets the caller keep the UI honest instead of
    /// showing an off switch that isn't.
    public static func set(_ enabled: Bool,
                           now: Date = Date(),
                           root: URL = StoreLocationPointer.defaultRoot()) throws {
        do {
            try publish(enabled: enabled, now: now, root: root)
        } catch {
            guard !enabled else { throw error }
            // Denial by absence is as good as denial by content.
            try? FileManager.default.removeItem(at: url(root: root))
            if isEnabled(root: root) { throw error }
        }
    }

    private static func publish(enabled: Bool, now: Date, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(MCPAccessGate(enabled: enabled, updatedAt: now))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url(root: root), options: .atomic)
    }
}

/// Thrown by the tool layer when the gate is closed. Carries the remedy,
/// because the person who sees this text is in an MCP client with no idea
/// which macOS app is refusing them or why.
public struct MCPAccessDisabledError: LocalizedError {
    public init() {}

    public var errorDescription: String? {
        """
        Mila's MCP access is turned off. Enable it in Mila under \
        Settings → Storage → "Allow MCP access to transcriptions". \
        It is off by default so that recordings are never exposed to an \
        assistant without you asking for it.
        """
    }
}
