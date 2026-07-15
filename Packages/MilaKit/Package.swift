// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MilaKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MilaKit", targets: ["MilaKit"]),
    ],
    targets: [
        .target(name: "MilaKit"),
        .testTarget(
            name: "MilaKitTests",
            dependencies: ["MilaKit"]
        ),
    ]
)
