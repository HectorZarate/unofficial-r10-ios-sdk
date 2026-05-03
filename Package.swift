// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "R10Kit",
    platforms: [
        // R10Connection is a CoreBluetooth-based actor; CoreBluetooth
        // is iOS-only. The package builds for the host platforms
        // Apple supports, but the SDK is functionally an iOS / iPadOS
        // / watchOS / tvOS / macOS-Catalyst library only.
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10),
        .tvOS(.v17),
    ],
    products: [
        .library(
            name: "R10Kit",
            targets: ["R10Kit"]
        ),
    ],
    targets: [
        .target(
            name: "R10Kit",
            path: "Sources/R10Kit"
        ),
        .testTarget(
            name: "R10KitTests",
            dependencies: ["R10Kit"],
            path: "Tests/R10KitTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
