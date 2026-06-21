# ADR-009：Phase 1 单 Xcode target，按模块分文件夹（不切 Swift Package）

> Status: Accepted
> Date: 2026-05-02
> Deciders: SieveAI
> Tags: build, infra

## Context

Sieve GUI Phase 1 是单人维护的中等规模 macOS App（~7 个功能模块，估计 15,000~25,000 行 Swift 代码）。

构建模型选择直接影响：
- 编译速度（增量构建效率）
- 模块边界执行（循环依赖、访问控制）
- CI 配置复杂度
- 第三方依赖集成（SQLite.swift / Sparkle）

约束：
- CLAUDE.md 明确规定单 target、文件 > 400 行 = 拆分信号、按模块分文件夹（[ADR-009](ADR-009-project-layout-single-target.md)）
- Phase 1 规模不需要跨 package 的代码共享
- Xcode Swift Package Manager (SPM) 集成在 Phase 1 不是必须的

## Options Considered

### Option 1：单 Xcode target + 文件夹划分（本方案）
- 优点：
  - 配置最简单（单 `.xcodeproj` + 单 scheme），CI 一条命令构建
  - 不需要管 Package.swift manifest，依赖（SQLite.swift / Sparkle）通过 Xcode Package Dependencies 统一管理
  - 文件夹划分（不是 group）在 Finder 中可见，代码组织清晰
  - `internal` 访问级别默认跨文件可见，不需要显式 `public` — Phase 1 模块间通信较频繁，强制 `public` 接口设计成本不值
  - 增量编译：单 target 内 Swift 的增量编译效率在文件 < 400 行的约束下是可接受的
- 缺点：
  - 无编译器级别的模块边界执行（只靠代码 review 约定）
  - 随着代码量增长，整体 clean build 时间会线性增加（但 Phase 1 规模下不是问题）
- 估计成本：最低

### Option 2：多个 Swift Package（本地 package，monorepo 内）
- 优点：
  - 编译器级别的访问控制（`internal` 不跨 package，必须 `public`）
  - 每个 package 独立增量编译，大型项目有优势
  - 可以独立测试每个 package（每个 package 自己的 test target）
- 缺点：
  - Package.swift 维护成本在 Phase 1 不值（7 个模块 × 平均 3K 行 = 21K 行，不到 SPM 优化的临界点）
  - 跨 package 共享 `AppState` 需要 `public` / `@_spi`，写法啰嗦
  - Xcode 对多 local package 的工程文件管理有时出现路径不稳定问题（Xcode 13/14 的已知 bug）
  - Phase 1 规模下，`public` 接口约束带来的收益有限，通过 code review 约定即可执行边界
- 估计成本：中高，不必要的复杂度

### Option 3：Framework targets（多 embedded framework）
- 优点：模块化，编译器隔离
- 缺点：Dynamic framework 在 macOS App 中需要 embed & sign，增加 binary 大小和 codesign 复杂度；Sparkle / SQLite.swift 本身是 framework，再套一层 framework 嵌套管理麻烦；与 ADR-001 notarization 简洁性目标冲突
- 估计成本：高，不值

## Decision

选择 Option 1：**单 Xcode target，按模块分文件夹**（物理目录，不是 Xcode group only）。

**目录结构**：

```
SieveGUI/
├── App/
│   ├── SieveGUIApp.swift        ← @main + AppDelegate
│   ├── AppState.swift           ← @Observable 全局状态
│   └── WindowManager.swift      ← 窗口单例化管理
│
├── Features/
│   ├── MenuBar/                 ← MenuBarController + MenuBarViewModel
│   ├── Hips/                    ← HipsPanelManager + HipsViewModel + HipsView
│   ├── Settings/                ← SettingsWindow + 各 Tab ViewModel + View
│   ├── History/                 ← HistoryWindow + HistoryViewModel
│   ├── Debug/                   ← DebugWindow + DebugViewModel
│   ├── Onboarding/              ← OnboardingWindow + OnboardingViewModel
│   └── Toast/                   ← ToastController + ToastView
│
├── Services/
│   ├── IPC/                     ← IPCClient + JSONRPCCodec + InflightQueue
│   ├── AuditDB/                 ← AuditDBReader + EventRow 映射
│   ├── TouchID/                 ← TouchIDService + TouchIDSession
│   ├── Notifications/           ← NotificationService (UNUserNotificationCenter)
│   └── Diagnostics/             ← DiagnosticPackager + RedactPipeline
│
├── Models/                      ← 共享模型：HipsRequest, HitSummary, GraylistEntry 等
│
├── UI/
│   └── Components/              ← MaskedField, CountdownBar, SeverityBadge 等可复用组件
│
└── Resources/
    ├── Localizable.xcstrings    ← String Catalogs
    ├── Assets.xcassets
    └── Info.plist
```

**文件大小约束**：单文件 > 400 行 = 拆分信号（CLAUDE.md 约束）。View / ViewModel / Service 各自独立文件，类名与文件名一致。

**依赖方向约束**（通过 code review 执行，无编译器强制）：
- `Features/*` 可依赖 `Services/*` 和 `Models`，不可依赖其他 `Features`
- `Services/*` 之间禁止互相依赖（通过 `AppState` 协调）
- `UI/Components` 不依赖任何 `Services` 或 `Features`

**测试 target**：`SieveGUITests`（同 target 内的 `.testTarget`），测试文件在 `Tests/` 目录镜像 `SieveGUI/` 结构。

## Consequences

**正面影响**：
- CI 构建命令：`xcodebuild -scheme SieveGUI -destination 'platform=macOS' test`
- 新功能开发只需在对应 `Features/` 子目录新建文件，不需要改 Package.swift
- 单 target 的 `-warnings-as-errors` 统一在 Build Settings 设置，不需要每个 package 重复配置

**引入的新约束**：
- 依赖方向只靠约定（code review checklist），无编译器执行；若 Phase 2 代码量 > 50K 行，需评估切 SPM
- 所有 `internal` 类型对整个 target 可见，要靠命名和文件夹组织防止误用（如 `HipsPanelManager.shared` 对所有代码可见）
- 文件 > 400 行时必须拆分，但单 target 下拆分只是新建文件，没有额外结构变更成本

**后续需要做的事**：
- Phase 2 评估：如果代码量超过 40K 行或有多人协作需求，重新评估 SPM 多 package 方案（届时写新 ADR 取代本 ADR）
- CI 配置写在 `Makefile` 或 `.github/workflows`，构建目标和测试目标明确化

## References

- CLAUDE.md 编码规范（文件组织 §）
- ADR-001（技术栈决策）：[`ADR-001-swiftui-native-only-stack.md`](ADR-001-swiftui-native-only-stack.md)
- [`docs/design/architecture.md`](../architecture.md) §4（模块边界与依赖）
- PRD §9 条 11（代码约束：SwiftUI/Swift 5.9+，一键构建）
