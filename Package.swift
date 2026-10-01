// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ToggleMouse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ToggleMouse",
            dependencies: ["ToggleMouseShared"],
            path: "Sources/ToggleMouse",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ToggleMouseHelper",
            dependencies: ["ToggleMouseShared"],
            path: "Sources/ToggleMouseHelper",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "ToggleMouseShared",
            path: "Sources/ToggleMouseShared",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ToggleMouseTests",
            dependencies: ["ToggleMouse"],
            path: "Tests/ToggleMouseTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
