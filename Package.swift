// swift-tools-version: 6.0

import PackageDescription

// The package holds the hardware-independent core so it can be tested with
// `swift test`. The menu-bar app is built from project.yml (XcodeGen).
let package = Package(
    name: "Purrthrough",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "PurrthroughCore", targets: ["PurrthroughCore"]),
    ],
    targets: [
        .target(name: "PurrthroughCore"),
        .testTarget(name: "PurrthroughCoreTests", dependencies: ["PurrthroughCore"]),
    ]
)
