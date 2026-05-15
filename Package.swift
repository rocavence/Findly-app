// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Findly",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Findly",
            path: "Sources/Findly"
        ),
        .testTarget(
            name: "FindlyTests",
            dependencies: ["Findly"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
