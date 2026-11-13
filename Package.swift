// swift-tools-version: 5.9

import PackageDescription
import Foundation

// The regular suite includes DEBUG-only UI fixtures. This explicit mode runs
// the real optimized reader and reconnect contracts without compiling those
// development harnesses.
// Product sources, compiler settings and ordinary full-suite coverage are unchanged.
let productionViewportChecks = ProcessInfo.processInfo.environment["NATIVE_PRODUCTION_VIEWPORT_CHECKS"] == "1"

let package = Package(
    name: "SynologyChatNative",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SynologyChatNative", targets: ["SynologyChatNative"])
    ],
    dependencies: [
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "SynologyChatNative",
            dependencies: [.product(name: "Sodium", package: "swift-sodium")],
            path: "Sources/SynologyChatNative",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SynologyChatNativeTests",
            dependencies: ["SynologyChatNative"],
            path: "Tests/SynologyChatNativeTests",
            sources: productionViewportChecks ? ["NativeProductionViewportTests.swift", "NativeProductionRichViewportTests.swift", "NativeProductionEnvironmentTests.swift", "NativeChatAppConfigurationTests.swift", "ChatMainHistoryRefreshTests.swift", "ChatMainReconnectHistoryTests.swift", "ChatMessageEditBaselineTests.swift", "ChatMessageEditConflictTests.swift"] : nil,
            resources: [.copy("Fixtures")]
        )
    ]
)
