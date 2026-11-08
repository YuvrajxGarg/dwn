// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Dwn",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Dwn",
            path: "Sources/Dwn",
            swiftSettings: [.unsafeFlags(["-Osize"])]
        )
    ]
)
