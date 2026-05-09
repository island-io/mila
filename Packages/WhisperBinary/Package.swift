// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperBinary",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Whisper", targets: ["whisper"])
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.8.4/whisper-v1.8.4-xcframework.zip",
            checksum: "1c7a93bd20fe4e57e0af12051ddb34b7a434dfc9acc02c8313393150b6d1821f"
        )
    ]
)
