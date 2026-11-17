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
    /// A second, separate consent: may `save_transcript` create or replace
    /// files on this Mac? Read access was all anyone agreed to before this
    /// existed, so a file written by an older build — which has no such key —
    /// decodes as `false`, and so does everything else the gate does not
    /// positively understand. Only meaningful with `enabled`: see
    /// `isFileExportEnabled(root:)`.
    public var fileExportEnabled: Bool
    public var updatedAt: Date

    public init(enabled: Bool, fileExportEnabled: Bool = false, updatedAt: Date) {
        self.enabled = enabled
        self.fileExportEnabled = fileExportEnabled
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, fileExportEnabled, updatedAt
    }

    /// `fileExportEnabled` is lenient (absent → `false`) so a gate file from
    /// before the key existed keeps granting what it granted then — reads —
    /// and nothing more. `enabled` stays strict: a file without it is not a
    /// file this gate understands, so it denies.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        fileExportEnabled = try c.decodeIfPresent(Bool.self, forKey: .fileExportEnabled) ?? false
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
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
        read(root: root)?.enabled ?? false
    }

    /// Whether `save_transcript` may write files. Requires BOTH flags: write
    /// consent is a refinement of read consent, never a substitute for it.
    /// Fails closed exactly like `isEnabled` — and, like it, is re-read on
    /// every tool call, so turning it off bites a server that is already
    /// running.
    public static func isFileExportEnabled(root: URL = StoreLocationPointer.defaultRoot()) -> Bool {
        guard let gate = read(root: root) else { return false }
        return gate.enabled && gate.fileExportEnabled
    }

    private static func read(root: URL) -> MCPAccessGate? {
        guard let data = try? Data(contentsOf: url(root: root)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MCPAccessGate.self, from: data)
    }

    /// Called by the app when the user flips either setting.
    ///
    /// ## Revoking has to fail closed
    ///
    /// The two directions are not symmetric, and treating them as one write
    /// is what made revocation fail OPEN (CodeRabbit on #183, CWE-359):
    ///
    ///   * Failing to publish a **grant** is safe. The file keeps whatever it
    ///     had, and every "anything I don't positively understand" case —
    ///     absent, unreadable, malformed — already denies. The worst outcome
    ///     is access the user asked for not arriving.
    ///   * Failing to publish a **revocation** is not. The previous file
    ///     survives the failed atomic write, so the toggle reads off in the
    ///     UI while a configured MCP client keeps reading transcripts (or
    ///     writing files) — indefinitely, and invisibly.
    ///
    /// There are two flags now, and the rule applies to each: a failed write
    /// that leaves the file granting MORE than was asked for — read access
    /// after `enabled: false`, file writes after `fileExport: false` —
    /// escalates to deleting the file, which denies both by absence. That can
    /// cost the read access a `(true, false)` call wanted to keep; denying
    /// too much is the fail-closed side, and the throw below reports it.
    ///
    /// `set` judges the END STATE. It throws when the gate still grants
    /// something that was withheld (the caller must keep its UI honest), or
    /// when something asked for did not land (safe, but the user should
    /// know). It returns normally whenever the gate grants exactly what was
    /// asked, even if the write itself failed.
    public static func set(_ enabled: Bool,
                           fileExport: Bool = false,
                           now: Date = Date(),
                           root: URL = StoreLocationPointer.defaultRoot()) throws {
        // Write consent without read consent is not a state the gate holds.
        let fileExport = enabled && fileExport
        do {
            try publish(enabled: enabled, fileExport: fileExport, now: now, root: root)
        } catch {
            func grantsMoreThanAsked() -> Bool {
                (isEnabled(root: root) && !enabled)
                    || (isFileExportEnabled(root: root) && !fileExport)
            }
            if !enabled || grantsMoreThanAsked() {
                // Denial by absence is as good as denial by content.
                try? FileManager.default.removeItem(at: url(root: root))
            }
            if grantsMoreThanAsked() { throw error }
            if enabled && !isEnabled(root: root) { throw error }
            if fileExport && !isFileExportEnabled(root: root) { throw error }
        }
    }

    private static func publish(enabled: Bool, fileExport: Bool, now: Date, root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(MCPAccessGate(enabled: enabled,
                                                    fileExportEnabled: fileExport,
                                                    updatedAt: now))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url(root: root), options: .atomic)
    }
}

/// Thrown by the tool layer when the gate is closed. Carries the remedy,
/// because the person who sees this text is in an MCP client with no idea
/// which macOS app is refusing them or why.
///
/// `CustomStringConvertible` as well as `LocalizedError`: `mila-mcp` hands
/// the client `String(describing: error)`, which ignores `errorDescription`
/// and would otherwise print the bare type name instead of the remedy.
public struct MCPAccessDisabledError: LocalizedError, CustomStringConvertible {
    public init() {}

    public var description: String { errorDescription ?? "" }

    public var errorDescription: String? {
        """
        Mila's MCP access is turned off. Enable it in Mila under \
        Settings → Storage → "Allow MCP access to transcriptions". \
        It is off by default so that recordings are never exposed to an \
        assistant without you asking for it.
        """
    }
}

/// Thrown by `save_transcript` when read access is on but the separate
/// file-export consent is not. Names both toggles, for the same reason as
/// `MCPAccessDisabledError`: the reader is in an MCP client, not in Mila.
public struct MCPFileExportDisabledError: LocalizedError, CustomStringConvertible {
    public init() {}

    public var errorDescription: String? {
        """
        Saving transcripts to files is turned off for Mila's MCP access. \
        Reading transcripts still works; to let an assistant write files, \
        enable "Also allow saving transcripts to files" in Mila under \
        Settings → Storage, beneath "Allow MCP access to transcriptions". \
        It is off by default, separately from read access, so that allowing \
        an assistant to read your recordings never also lets it write files.
        """
    }

    public var description: String { errorDescription ?? "" }
}
