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
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "PDFCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "pdf",
            dependencies: [
                "PDFCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "PDFCoreTests",
            dependencies: ["PDFCore"]
        ),
    ]
)
