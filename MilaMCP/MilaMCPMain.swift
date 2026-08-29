import Foundation
import MCP
import MilaKit

/// mila-mcp — MCP stdio server exposing Mila's transcriptions to Claude
/// (Claude Code / Claude Desktop). Register once with:
///
///     claude mcp add mila -- /Applications/Mila.app/Contents/MacOS/mila-mcp
///
/// All tool logic lives in MilaKit's `MilaMCPToolHandlers` (pure
/// JSON-in/JSON-out); this file is only the SDK/transport shell.
@main
struct MilaMCPMain {

    static func main() async throws {
        let root = storeRoot()
        let handlers = MilaMCPToolHandlers(root: root)

        let tools: [Tool] = try MilaMCPToolHandlers.toolSpecs.map { spec in
            let schemaData = try JSONSerialization.data(withJSONObject: spec.inputSchema)
            let schema = try JSONDecoder().decode(Value.self, from: schemaData)
            return Tool(name: spec.name, description: spec.description, inputSchema: schema)
        }

        let server = Server(
            name: "mila",
            version: appVersion(),
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                let arguments = try jsonObject(from: params.arguments)
                let result = try handlers.handle(tool: params.name, arguments: arguments)
                return CallTool.Result(content: [.text(result)], isError: false)
            } catch {
                return CallTool.Result(content: [.text(String(describing: error))],
                                       isError: true)
            }
        }

        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    /// The app-support root every cross-process contract is resolved from.
    ///
    /// ## Why the env override is not in release builds
    ///
    /// `root` is not just "where the recordings are" — **all three** contracts
    /// hang off it, and two of them are trust decisions:
    ///
    ///   * `<root>/mcp-access.json` — the consent gate. `handle(tool:)` asks
    ///     `MCPAccessGate.isEnabled(root:)` with this exact root.
    ///   * `<root>/store-location.json` — the store pointer, whose
    ///     `recordingsDirectory` / `storeFile` are ABSOLUTE paths that may
    ///     name any directory at all.
    ///   * `<root>/live/current.json` — the live transcript sidecar.
    ///
    /// So an attacker who can set one environment variable for this process
    /// — and an MCP client config is exactly that, whether via
    /// `claude mcp add … -e` or an edited config file — could point `root` at
    /// a directory they control, drop in their own `mcp-access.json` saying
    /// `enabled: true`, and a `store-location.json` aimed at Mila's real
    /// recordings. The gate would then read the attacker's consent file,
    /// answer yes, and the reader would serve the user's real transcripts.
    /// Consent granted by the party being consented to is not consent, and
    /// the opt-in gate is the entire security basis of this feature — so the
    /// override must not exist in a shipped binary. (CodeRabbit on #183,
    /// CWE-284.)
    ///
    /// Debug builds keep it for driving the helper against a fixture store by
    /// hand. `-DDEBUG` is present on this target's Debug compile and absent
    /// in Release, so the shipped helper has no branch here at all: it is
    /// unconditionally the default app-support root.
    ///
    /// No test depends on this: `MILA_ROOT` appears nowhere else in the
    /// repository, and MilaKit's tests inject a fixture root straight into
    /// `MilaMCPToolHandlers(root:)` rather than going through the executable.
    /// Gating it therefore cannot silently redirect a test at the real store.
    private static func storeRoot() -> URL {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["MILA_ROOT"] {
            FileHandle.standardError.write(Data(
                "mila-mcp: DEBUG build honouring MILA_ROOT=\(override)\n".utf8))
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        #endif
        return StoreLocationPointer.defaultRoot()
    }

    /// Bridge the SDK's `Value` arguments into the Foundation JSON tree
    /// the handler layer consumes.
    private static func jsonObject(from arguments: [String: Value]?) throws -> [String: Any] {
        guard let arguments, !arguments.isEmpty else { return [:] }
        let data = try JSONEncoder().encode(arguments)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    /// The helper ships inside Mila.app — report the app's version when
    /// we can find it (…/Mila.app/Contents/MacOS/mila-mcp → Info.plist),
    /// so `initialize` handshakes identify the build.
    private static func appVersion() -> String {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let infoPlist = binary
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
            .appendingPathComponent("Info.plist")
        if let info = NSDictionary(contentsOf: infoPlist),
           let version = info["CFBundleShortVersionString"] as? String {
            return version
        }
        return "dev"
    }
}
