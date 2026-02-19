// swift-tools-version: 6.2

import PackageDescription

let concurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "GhostOS",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "GhostOS", targets: ["GhostOS"]),
        .executable(name: "ghost", targets: ["ghost"]),
    ],
    dependencies: [
        .package(path: "../AXorcist"),
    ],
    targets: [
        .target(
            name: "GhostOS",
            dependencies: [
                .product(name: "AXorcist", package: "AXorcist"),
            ],
            path: "Sources/GhostOS",
            swiftSettings: concurrencySettings,
            linkerSettings: [.linkedFramework("ScreenCaptureKit")]
        ),
        .executableTarget(
            name: "ghost",
            dependencies: ["GhostOS"],
            path: "Sources/ghost",
            swiftSettings: concurrencySettings
        ),
        .testTarget(
            name: "GhostOSTests",
            dependencies: ["GhostOS"],
            path: "Tests/GhostOSTests",
            swiftSettings: concurrencySettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
