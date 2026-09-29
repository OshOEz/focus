// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Focus",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "FocusCore"),
        .executableTarget(name: "ax-dump", dependencies: ["FocusCore"], path: "Tools/ax-dump"),
        .testTarget(name: "FocusCoreTests", dependencies: ["FocusCore"]),
    ]
)
