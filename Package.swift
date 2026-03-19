// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VocalFlow",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "VocalFlow",
            path: "Sources/VocalFlow"
        )
    ]
)
