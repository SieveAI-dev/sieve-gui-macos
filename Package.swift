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
                // App 入口/AppKit 相关留给 xcodebuild；AppState 是纯逻辑（无 AppKit
                // 依赖），单独纳入核心库以便 swift test 守护菜单栏状态机（见 sources）。
                "App/AppDelegate.swift",
                "App/AppStateIPCAdapter.swift",
                "App/DebugReplayStore.swift",
                "App/SieveGUIApp.swift",
                "App/WindowManager.swift",
                "Features/Debug",
                "Features/HIPS",
                "Features/MenuBar",
                "Features/Onboarding",
                "Features/Settings",
                "Features/Toast",
                "Features/History/HistoryWindowView.swift",
                "Features/History/HistoryExporter.swift",
                "Features/History/InspectorPanelView.swift",
                "Features/History/HistoryMaskPolicy.swift",
                "Resources",
                "Services/Sparkle",
                "Services/Notifications",
                "Services/TouchID",
                "UI"
            ],
            sources: [
                "Models",
                "Services/IPC",
                "Services/AuditDB",
                "Services/Diagnostic",
                "Services/Logger",
                "Services/Telemetry",
                "Services/SieveBinaryLocator.swift",
                "Features/History/HistoryWindowViewModel.swift",
                "App/AppState.swift"
            ]
        ),
        .testTarget(
            name: "SieveGUICoreTests",
            dependencies: ["SieveGUICore"],
            path: "Tests/SieveGUITests",
            // SPEC-005 §14.2：daemon 权威 fixture 副本，IPCSchemaV2FixtureTests 经
            // Bundle.module 消费，校验 GUI 解码与 daemon 序列化对齐（防 schema 漂移）。
            resources: [.copy("Fixtures")]
        )
    ]
)
