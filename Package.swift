// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Chimera",
    defaultLocalization: "zh-Hans",
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
            // 本地化资源(en/zh-Hans 的 Localizable.strings 与 InfoPlist.strings);
            // 打包时由 scripts/make-app.sh 把 .lproj 平铺进 .app main bundle
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ChimeraCoreTests",
            dependencies: ["ChimeraCore", "CChmlib"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
