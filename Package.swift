// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ivy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "IvyCore", targets: ["IvyCore"]),
        .executable(name: "Ivy", targets: ["Ivy"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "IvyCore",
            dependencies: [],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "Ivy",
            dependencies: ["IvyCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "IvyTests",
            dependencies: ["IvyCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
