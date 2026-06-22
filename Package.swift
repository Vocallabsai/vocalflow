// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VocalFlow",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "VocalFlow",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/VocalFlow",
            linkerSettings: [
                // The app bundle is hand-assembled, so the executable must be
                // able to find the embedded Sparkle.framework at runtime.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(
            name: "VocalFlowTests",
            dependencies: ["VocalFlow"],
            path: "Tests/VocalFlowTests"
        )
    ]
)
