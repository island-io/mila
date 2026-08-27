// swift-tools-version: 5.10
import PackageDescription

/// Full Sendable checking under the Swift 5 language mode.
///
/// The app project is Swift 5.10, so nothing here is checked by default —
/// and that is exactly how `MilaMCPToolHandlers` came to be captured into
/// the MCP SDK's `@escaping @Sendable` `CallTool` handler while holding a
/// non-`Sendable` `MilaDataSource` existential (CodeRabbit on #183). This
/// package is the whole cross-process surface mila-mcp runs concurrently
/// against, so it opts in: the conformances are now compiler-verified
/// rather than asserted, and a future non-`Sendable` field on any of these
/// types is a diagnostic instead of a silent regression.
let strictConcurrency: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
]

let package = Package(
    name: "MilaKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MilaKit", targets: ["MilaKit"]),
    ],
    targets: [
        .target(name: "MilaKit", swiftSettings: strictConcurrency),
        .testTarget(
            name: "MilaKitTests",
            dependencies: ["MilaKit"],
            swiftSettings: strictConcurrency
        ),
    ]
)
