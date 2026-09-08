// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "InfraredConverter",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "InfraredConverter",
            path: "Sources/InfraredConverter"
        ),
        .testTarget(
            name: "InfraredConverterTests",
            dependencies: ["InfraredConverter"],
            path: "Tests/InfraredConverterTests"
        )
    ]
)
