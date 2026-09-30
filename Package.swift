// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Focus",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "FocusCore"),
        .target(
            name: "GazeKit",
            dependencies: ["FocusCore"],
            resources: [.copy("Resources/blazegaze.mlmodelc"), .copy("Resources/face_mesh.mlmodelc")]
        ),
        .executableTarget(name: "focus-gaze", dependencies: ["GazeKit", "FocusCore"], path: "Tools/focus-gaze"),
        .target(name: "FocusMac", dependencies: ["FocusCore"]),
        .executableTarget(name: "ax-dump", dependencies: ["FocusCore", "FocusMac"], path: "Tools/ax-dump"),
        .executableTarget(name: "Focus", dependencies: ["FocusCore", "GazeKit", "FocusMac"], path: "Sources/FocusApp"),
        .executableTarget(name: "focus-bench", dependencies: ["FocusCore", "GazeKit", "FocusMac"], path: "Sources/FocusBench"),
        .executableTarget(name: "focus-fixture", dependencies: ["FocusMac"], path: "Sources/FocusFixture"),
        .testTarget(name: "FocusCoreTests", dependencies: ["FocusCore"],
                    resources: [.copy("Fixtures/settings-v1.json"), .copy("Fixtures/setup-v1.json")]),
        .testTarget(name: "GazeKitTests", dependencies: ["GazeKit", "FocusCore"],
                    resources: [.copy("Fixtures/portrait.jpg")]),
        .testTarget(name: "FocusMacTests", dependencies: ["FocusMac", "FocusCore"]),
    ]
)
