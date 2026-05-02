// swift-tools-version: 5.9
import PackageDescription

// 这是 Swift Package Manager 描述文件，仅用于 CI lint / swift-format / 命令行测试
// 真实 macOS App target 通过 XcodeGen 从 project.yml 生成 .xcodeproj 构建

let package = Package(
    name: "SieveGUICore",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SieveGUICore", targets: ["SieveGUICore"])
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.0")
    ],
    targets: [
        .target(
            name: "SieveGUICore",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift")
            ],
            path: "Sources",
            exclude: [
                "App",
                "Features",
                "Resources",
                "Services/Sparkle",
                "Services/Notifications",
                "Services/TouchID",
                "Services/Diagnostic",
                "UI"
            ],
            sources: [
                "Models",
                "Services/IPC",
                "Services/AuditDB",
                "Services/Logger",
                "Services/Telemetry"
            ]
        ),
        .testTarget(
            name: "SieveGUICoreTests",
            dependencies: ["SieveGUICore"],
            path: "Tests/SieveGUITests"
        )
    ]
)
