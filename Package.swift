// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AISwitchboard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AISwitchboard",
            path: "Sources/AISwitchboard"
        )
    ]
)
