// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Trackify",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TrackifyDomain", targets: ["TrackifyDomain"]),
        .library(name: "TrackifyStore", targets: ["TrackifyStore"]),
        .library(name: "TrackifyEngine", targets: ["TrackifyEngine"]),
        .executable(name: "trackify", targets: ["TrackifyCLI"]),
        .executable(name: "TrackifyMac", targets: ["TrackifyMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.2"),
    ],
    targets: [
        .target(name: "TrackifyDomain"),
        .target(
            name: "TrackifyStore",
            dependencies: [
                "TrackifyDomain",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "TrackifyEngine",
            dependencies: ["TrackifyDomain", "TrackifyStore"]
        ),
        .executableTarget(
            name: "TrackifyCLI",
            dependencies: [
                "TrackifyDomain",
                "TrackifyStore",
                "TrackifyEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "TrackifyMac",
            dependencies: [
                "TrackifyDomain",
                "TrackifyStore",
                "TrackifyEngine",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Apps/TrackifyMac",
            exclude: ["Info.plist.template", "Trackify.entitlements"]
        ),
        .testTarget(
            name: "TrackifyDomainTests",
            dependencies: ["TrackifyDomain"]
        ),
        .testTarget(
            name: "TrackifyStoreTests",
            dependencies: [
                "TrackifyDomain",
                "TrackifyStore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "TrackifyEngineTests",
            dependencies: ["TrackifyDomain", "TrackifyStore", "TrackifyEngine"]
        ),
        .testTarget(
            name: "TrackifyCLITests",
            dependencies: ["TrackifyCLI"]
        ),
        .testTarget(
            name: "TrackifyMacTests",
            dependencies: ["TrackifyDomain", "TrackifyEngine", "TrackifyMac"]
        ),
    ]
)
