// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ToggleMouse",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ToggleMouse",
            path: "Sources/ToggleMouse",
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
