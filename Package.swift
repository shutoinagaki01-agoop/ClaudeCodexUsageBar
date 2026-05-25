// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeCodexUsageBar",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "ClaudeCodexUsageBar", targets: ["ClaudeCodexUsageBar"])
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCodexUsageBar",
            path: "Sources/ClaudeCodexUsageBar"
        )
    ]
)
