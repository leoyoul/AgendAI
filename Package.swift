// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgendAI",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AItingjiCore", targets: ["AItingjiCore"]),
        .executable(name: "AItingjiApp", targets: ["AItingjiApp"]),
        .executable(name: "AItingjiCaptureSmoke", targets: ["AItingjiCaptureSmoke"]),
        .executable(name: "AItingjiLiveSmoke", targets: ["AItingjiLiveSmoke"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.6")
    ],
    targets: [
        .target(
            name: "AItingjiCore",
            path: "Sources/AItingjiCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "AItingjiApp",
            dependencies: [
                "AItingjiCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/AItingjiApp"
        ),
        .executableTarget(
            name: "AItingjiCaptureSmoke",
            dependencies: ["AItingjiCore"],
            path: "Sources/AItingjiCaptureSmoke"
        ),
        .executableTarget(
            name: "AItingjiLiveSmoke",
            dependencies: ["AItingjiCore"],
            path: "Sources/AItingjiLiveSmoke"
        ),
        .testTarget(
            name: "AItingjiCoreTests",
            dependencies: ["AItingjiCore"],
            path: "tests/AItingjiCoreTests"
        ),
        .testTarget(
            name: "AItingjiAppTests",
            dependencies: ["AItingjiApp", "AItingjiCore"],
            path: "tests/AItingjiAppTests"
        )
    ]
)
