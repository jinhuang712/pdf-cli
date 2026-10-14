// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "pdf-cli",
    // The oldest supported macOS is still open (DESIGNS.md → Open questions).
    // The spike builds against macOS 14 and gates newer APIs with availability checks.
    platforms: [.macOS(.v14)],
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
