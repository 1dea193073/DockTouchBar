// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DockTouchBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DockTouchBar",
            path: "Sources/DockTouchBar"
        )
    ]
)
