// swift-tools-version: 5.9
import PackageDescription

// KeyflashCore and keyflash-run are plain Foundation/POSIX code, so they (and
// the tests) also build on Linux. The menu bar app needs AppKit/SwiftUI and is
// only part of the package on macOS.

var products: [Product] = [
    .executable(name: "keyflash-run", targets: ["keyflash-run"]),
]

var targets: [Target] = [
    .executableTarget(
        name: "keyflash-run",
        dependencies: [
            .target(name: "KeyflashCore"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]
    ),
    .target(
        name: "KeyflashCore",
        dependencies: [
            .product(name: "Yams", package: "Yams"),
        ]
    ),
    .testTarget(
        name: "KeyflashCoreTests",
        dependencies: [
            .target(name: "KeyflashCore"),
            .target(name: "keyflash-run"),
        ]
    ),
]

#if os(macOS)
products.append(.executable(name: "keyflash", targets: ["keyflash"]))
targets.append(
    .executableTarget(
        name: "keyflash",
        dependencies: [
            .target(name: "KeyflashCore"),
            .product(name: "Yams", package: "Yams"),
        ]
    )
)
#endif

let package = Package(
    name: "keyflash",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: targets
)
