// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BetterWeb",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BetterWeb",
            path: "Sources/BetterWeb",
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),
    ]
)
