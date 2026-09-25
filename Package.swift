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
        .executable(name: "ChimeraApp", targets: ["ChimeraGUI"]),
    ],
    targets: [
        // Vendored chmlib 0.40a (LGPL-2.1, 见 Sources/CChmlib/COPYING.LGPL
        // 与 docs/THIRD_PARTY_NOTICES.md)
        .target(
            name: "CChmlib"
        ),
        .target(
            name: "ChimeraCore",
            dependencies: ["CChmlib"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ChimeraApp",
            dependencies: ["ChimeraCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ChimeraGUI",
            dependencies: ["ChimeraCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ChimeraCoreTests",
            dependencies: ["ChimeraCore", "CChmlib"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
