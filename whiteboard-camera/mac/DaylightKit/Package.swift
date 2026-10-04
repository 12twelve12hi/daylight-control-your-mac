// swift-tools-version:5.9
// DaylightKit: the pure, Foundation-only core of Daylight (protocol, governor, spring, layout, canvas model,
// HTTP/WebSocket framing, mirror parsers, settings). Builds and tests on Linux and macOS.
import PackageDescription

let package = Package(
    name: "DaylightKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DaylightKit", targets: ["DaylightKit"]),
    ],
    targets: [
        .target(
            name: "DaylightKit",
            path: "Sources/DaylightKit"
        ),
        .testTarget(
            name: "DaylightKitTests",
            dependencies: ["DaylightKit"],
            path: "Tests/DaylightKitTests",
            resources: [.copy("Resources/solstream-v1.json"), .copy("Resources/fuzz-corpus.json")]
        ),
    ]
)
