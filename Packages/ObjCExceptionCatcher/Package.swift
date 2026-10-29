// swift-tools-version: 5.10
import PackageDescription

/// The one piece of Objective-C in Mila: a `@try/@catch` around a block.
///
/// Swift cannot catch an `NSException` — one that unwinds into Swift frames
/// terminates the process. `AVAudioEngine` reports some failures that way
/// rather than through `NSError`, notably `installTap` when the format it is
/// handed no longer matches the hardware (#385: AirPods switching to their
/// call profile mid-bring-up aborted the whole app). This package exists so
/// those call sites can turn the exception into an ordinary Swift error.
///
/// A package rather than a bridging header on the app target: the test
/// bundle and any future target get it with a plain `import`, and it is
/// tested on its own with `swift test`, no app host needed.
let package = Package(
    name: "ObjCExceptionCatcher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ObjCExceptionCatcher", targets: ["ObjCExceptionCatcher"]),
    ],
    targets: [
        .target(name: "ObjCExceptionCatcher"),
        .testTarget(
            name: "ObjCExceptionCatcherTests",
            dependencies: ["ObjCExceptionCatcher"]
        ),
    ]
)
