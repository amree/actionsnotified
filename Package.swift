// swift-tools-version: 5.9
// For SourceKit / IDE type resolution only — build with `make`.
import PackageDescription

let package = Package(
    name: "ActionsNotified",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "ActionsNotified",
            path: "Sources/ActionsNotified"
        ),
        .testTarget(
            name: "ActionsNotifiedTests",
            dependencies: ["ActionsNotified"],
            path: "Tests/ActionsNotifiedTests"
        )
    ]
)
