// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "VMDefaults",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "VMDefaults",
            targets: ["VMDefaults"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "VMDefaults",
            swiftSettings: [
                // Make the strict-concurrency contract self-documenting (and guard against a future
                // tools-version downgrade) rather than relying on the tools-version 6.2 default.
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "VMDefaultsTests",
            dependencies: ["VMDefaults"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Compiled home for the snippets in Examples/, so they cannot drift from the public API.
        // Built by `swift build`; not exposed as a product.
        .target(
            name: "Examples",
            dependencies: ["VMDefaults"],
            path: "Examples",
            exclude: ["README.md"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
