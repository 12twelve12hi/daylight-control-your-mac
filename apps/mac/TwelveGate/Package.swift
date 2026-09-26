// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TwelveGate",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "TwelveGate",
            path: "Sources/TwelveGate"
        )
    ]
)
