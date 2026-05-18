// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "SynologyChatNative",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SynologyChatNative", targets: ["SynologyChatNative"])
    ],
    targets: [
        .executableTarget(
            name: "SynologyChatNative",
            path: "Sources/SynologyChatNative"
        )
    ]
)
