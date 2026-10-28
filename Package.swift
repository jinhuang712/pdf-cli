// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pdf-cli",
    // macOS 12 is the oldest supported version (plan/decisions/062-macos-12-as-the-oldest-supported-version.md).
    // Newer APIs are gated with availability checks.
    platforms: [.macOS(.v12)],
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
        // Tests of the command line itself, such as the agent guide against the subcommands.
        .testTarget(
            name: "pdfTests",
            dependencies: [
                "pdf",
                "PDFCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
