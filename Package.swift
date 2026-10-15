// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pdf-cli",
    // macOS 11 is the oldest supported version (DESIGNS.md → Decision: macOS 11 as the oldest
    // supported version). Newer APIs are gated with availability checks.
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "pdf", targets: ["pdf"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    ],
    targets: [
        .executableTarget(
            name: "pdf",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
