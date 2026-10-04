// swift-tools-version: 5.9
import Foundation
import PackageDescription

// libBetterWebEngine and the Ladybird libraries it links are built by scripts/build_ladybird_engine.sh.
let ladybirdBuild = ProcessInfo.processInfo.environment["LADYBIRD_BUILD_DIR"]
    ?? "\(ProcessInfo.processInfo.environment["HOME"] ?? "")/Documents/GitHub/ladybird/Build/release"

let package = Package(
    name: "BetterWeb",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "BWEngine",
            path: "Sources/BWEngine"
        ),
        .executableTarget(
            name: "BetterWeb",
            dependencies: ["BWEngine"],
            path: "Sources/BetterWeb",
            linkerSettings: [
                .unsafeFlags([
                    "-L", "\(ladybirdBuild)/lib",
                    "-lBetterWebEngine",
                    "-lc++",
                    // Bundled app: Contents/lib. `swift run`: the Ladybird build tree.
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../lib",
                    "-Xlinker", "-rpath", "-Xlinker", ladybirdBuild + "/lib",
                    "-Xlinker", "-rpath", "-Xlinker", ladybirdBuild + "/vcpkg_installed/arm64-osx-dynamic/lib",
                ]),
            ]
        ),
    ]
)
