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
        .executableTarget(name: "ax-dump", dependencies: ["FocusCore"], path: "Tools/ax-dump"),
        .testTarget(name: "FocusCoreTests", dependencies: ["FocusCore"]),
        .testTarget(name: "GazeKitTests", dependencies: ["GazeKit", "FocusCore"],
                    resources: [.copy("Fixtures/portrait.jpg")]),
    ]
)
