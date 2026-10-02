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
            exclude: [
                "Resources/Info.plist",
                "Resources/Ivy.entitlements",
                "Resources/AppIcon.icns"
            ],
            resources: [.copy("Resources/IvyAppIcon.png"), .copy("Resources/IvyCompanionSprites.png")],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Ivy/Resources/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "IvyTests",
            dependencies: ["IvyCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "IvyUITests",
            dependencies: ["Ivy", "IvyCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
