// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chimera",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ChimeraCore", targets: ["ChimeraCore"]),
        .executable(name: "chimera", targets: ["ChimeraApp"]),
    ],
    targets: [
        .target(
            name: "ChimeraCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ChimeraApp",
            dependencies: ["ChimeraCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ChimeraCoreTests",
            dependencies: ["ChimeraCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
