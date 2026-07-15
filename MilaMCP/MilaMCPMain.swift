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
        let handlers = MilaMCPToolHandlers()

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
