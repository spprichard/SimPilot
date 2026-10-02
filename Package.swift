// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SimPilot",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "simpilot", targets: ["simpilot"]),
        .library(name: "SimPilotCore", targets: ["SimPilotCore"]),
    ],
    dependencies: [
        // Switch to .package(url: "https://github.com/spprichard/SwiftJev.git", from: "0.1.0") once published changes are needed.
        .package(path: "../TypeSafeAI"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "SimPilotCore",
            dependencies: [
                .product(name: "TypeSafe", package: "TypeSafeAI"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "simpilot",
            dependencies: [
                "SimPilotCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "TypeSafe", package: "TypeSafeAI"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "SimPilotCoreTests",
            dependencies: [
                "SimPilotCore",
                .product(name: "TypeSafe", package: "TypeSafeAI"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
