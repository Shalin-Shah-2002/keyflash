// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "keyflash",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "keyflash", targets: ["keyflash"]),
        .executable(name: "keyflash-run", targets: ["keyflash-run"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "keyflash",
            dependencies: [
                .target(name: "KeyflashCore"),
                .product(name: "Yams", package: "Yams"),
            ]
        ),
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
    ]
)
