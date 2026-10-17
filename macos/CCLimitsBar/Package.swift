// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CCLimitsBar",
    platforms: [.macOS(.v12)],
    targets: [
        // чистый разбор и сборка cc-limits.json - без AppKit и SwiftUI,
        // чтобы самый опасный код (запись чужого конфига) был под тестами
        .target(name: "CCLimitsCore"),
        .executableTarget(name: "CCLimitsBar", dependencies: ["CCLimitsCore"]),
        .testTarget(name: "CCLimitsCoreTests", dependencies: ["CCLimitsCore"]),
    ]
)
