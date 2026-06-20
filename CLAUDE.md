# CLAUDE.md — Sieve GUI for macOS

本文件给 Claude / AI 助手用。全局规则继承 `~/.claude/CLAUDE.md`，本文件只写本仓库特有约束。

---

## 一句话项目定位

Sieve GUI 是 [Sieve daemon](#上游-daemon) 的 native macOS 守门人壳：常驻菜单栏、HIPS 弹窗、读 audit.db 给历史。**daemon 做检测，GUI 只做交互。**

完整定位见 `docs/requirements/sieve-gui-macos-prd-v1.0.md`。

---

## 技术栈（硬约束，不可更换）

- **macOS 13+ / SwiftUI / Combine / SQLite.swift / Network.framework**
- 第三方依赖白名单：`SQLite.swift`、`Sparkle`。其他一律 reject。
- **不引入** Electron / Tauri / Catalyst / SwiftCrossUI / Objective-C++ / RxSwift。
- 决策依据：[ADR-001](docs/design/adr/ADR-001-swiftui-native-only-stack.md)，呼应上游 [ADR-012](docs/external/upstream-references.md#adr-012)。

## 进程模型

- `LSUIElement = true`（accessory app，不进 Dock）
- 菜单栏 `NSStatusItem` + 多个 SwiftUI `Window` scene（设置/历史/调试/Onboarding）
- HIPS 弹窗是 `NSPanel` `.floating` 浮窗（独立生命周期）
- IPC：Unix Domain Socket `~/.sieve/ipc.sock`（JSON-RPC 2.0，**协议 v2**，与上游 daemon SPEC-005 v2 对齐）

## 常用命令

工程是双轨：`Package.swift` 只编译 Core 库（Models / IPC / AuditDB / Logger / Telemetry）供命令行测试；完整 App 走 XcodeGen 生成 `.xcodeproj`。

```bash
# 生成 Xcode 工程（修改 project.yml 后必跑）
xcodegen generate

# 命令行：编译 + 测试 Core 库（最快反馈，CI 用这条）
swift build
swift test

# 跑单个测试（filter 接 TestSuite 或 TestSuite/testName）
swift test --filter SieveGUICoreTests.HipsRequestDecoderTests
swift test --filter SieveGUICoreTests.HipsRequestDecoderTests/testRejectsUnknownProtocolVersion

# 完整 App 构建（产物 SieveGUI.app，用户可见显示名仍为 Sieve GUI）
xcodebuild -project SieveGUI.xcodeproj -scheme SieveGUI -destination 'platform=macOS' build

# Xcode 内 Run / 调试
open SieveGUI.xcodeproj
```

注意：

- App target 的 UI / Features / Sparkle 等代码**只能**经 xcodebuild 编译，`swift build` 会按 `Package.swift` 的 `exclude` 跳过。改完 UI 跑 `swift test` 不会触发 UI 层编译错误，必须 `xcodebuild` 才算验证。
- mock daemon 还没接好，联调直接连真 sieve daemon（`~/.sieve/ipc.sock`），daemon 不在时 GUI 进入 disconnected。

## 代码结构概览

```
Sources/
├── App/         入口（@main、AppDelegate、生命周期）
├── Models/      Codable IPC payload + 领域类型（HipsRequest / DecisionResponse / HitSummary / UserSettings …）
├── Services/    无 UI 副作用的服务层
│   ├── IPC/         Unix Socket 客户端、JSON-RPC 2.0、InflightQueue、协议版本握手
│   ├── AuditDB/     SQLite.swift 只读 audit.db
│   ├── Logger/      GUI 自身日志（不复用 daemon 通道）
│   ├── Telemetry/   匿名指标
│   ├── Sparkle/     自动更新（决策路径外）
│   ├── Notifications/ 通知中心封装
│   ├── TouchID/     LocalAuthentication 包装
│   └── Diagnostic/  脱敏诊断包导出
├── Features/    每个面是一个文件夹：HIPS / MenuBar / History / Settings / Debug / Onboarding / Toast
│                每个 Feature 内部 = ViewModel（@Observable）+ View + 子组件
├── UI/          跨 Feature 复用的 SwiftUI 组件（含 MaskedField 等红线组件）
└── Resources/   xcstrings、图标
```

数据流单向：`daemon → IPC → Models → Feature ViewModel → SwiftUI View`；用户答复反向 `View → ViewModel → IPC.send → daemon`。决策路径**不**经过 Services/Sparkle / Notifications。

理解任何 Feature 时，先读 `Features/<X>/<X>ViewModel.swift` 摸状态机，再读对应 SPEC 对照红线，最后看 View。

## 文档体系

本仓库严格遵循全局 DOCS-STANDARD v2.0（见 [`docs/DOCS-STANDARD.md`](docs/DOCS-STANDARD.md)）。

- 修改任何**功能代码**前，先读对应模块的 SPEC（`docs/specs/SPEC-NNN-*.md`）
- 修改任何**架构相关**代码前，先读 [`docs/design/architecture.md`](docs/design/architecture.md) + 相关 ADR
- 修改任何与 daemon 交互的代码前，先读 [`docs/api/ipc-protocol.md`](docs/api/ipc-protocol.md)
- ADR 只增不改，决策变了写新 ADR 把旧的标记为「被取代」

## 上游 daemon

本仓库的所有 IPC 行为、规则字段、`allow_remember` 计算逻辑都由 daemon 决定。
**GUI 不发明协议字段，不改写 daemon 推送的值。**

上游契约清单见 [`docs/external/upstream-references.md`](docs/external/upstream-references.md)。
任何 IPC 字段或行为变更必须**两个仓库同时改 SPEC + 协议版本号**。

---

## 硬约束（违反 = reject PR）

与 PRD §9 完全对齐，关键几条：

1. **`allow_remember == false` 时，HIPS 弹窗禁止渲染 Remember checkbox**（不允许灰显代替）。这是 [ADR-021 三道防线第三道](docs/external/upstream-references.md#adr-021)。
2. **GUI 决策路径不联网**。Sparkle 检查更新和 external link 例外，且二者不影响 HIPS 弹窗。
3. **不存储原始 prompt / 命中片段**。daemon 推送的 evidence 只在内存中持有，弹窗关闭即丢弃。
4. **HIPS 主按钮在 `recommendation` 缺失或 `confidence != high` 时永远是「拒绝」**。键盘 Return 默认到拒绝。
5. **协议版本不识别 → disconnected**。不允许向后兼容字段嗅探。
6. **菜单栏状态以 `sieve.hello` 实际握手为准**，不允许"假装健康"。
7. **导出诊断包默认脱敏**，不依赖用户阅读条款。
8. **写文件操作走 atomic rename**（preset 缓存 / 用户设置 / GUI log）。

---

## 编码规范增量（在全局 CLAUDE.md 之上）

### Swift

- Swift 5.9+，开启 `-warnings-as-errors`
- 文件顶部不写 `// Created by ...` 自动注释（已在 Xcode 模板里关掉）
- 所有 IPC 消息走 `Codable` 结构体，禁止 `[String: Any]` 透传
- 异步：`async/await` 优先，`Task` 取消必须传播
- UI 状态：`@State` / `@Observable`（macOS 14+）/ `Combine` `@Published`，三选一在每个模块内一致
- 不在 SwiftUI View 里写业务逻辑；ViewModel 用 `@Observable`

### 字符串

- 用户可见文案一律走 String Catalogs（`Localizable.xcstrings`）
- 调试日志可硬编码英文，但**不要**机翻中文
- 敏感字段（地址、密钥、tool input）的渲染必须走 `MaskedField` 组件，禁止裸 `Text(...)`

### 测试

- 单元测试：`swift testing` 框架（`@Test` macro）
- IPC 客户端必须有 mock daemon harness（见 [`docs/guides/development.md`](docs/guides/development.md)）
- HIPS 弹窗的关键约束（Remember 渲染 / 主按钮位置 / 倒计时阶段切换）必须有快照/行为测试

### 文件组织

- 单 target，按模块分文件夹（见 [ADR-009](docs/design/adr/ADR-009-project-layout-single-target.md)）
- 文件 > 400 行 = 拆分信号
- 一个 `View` / `Model` / `Service` 一个文件，类名与文件名一致

---

## 工作流增量

- **进度真实源**：所有任务从 `tasks/PROGRESS.md` 拉取，完成后立即勾选 + 移到「已完成」段并写一句话总结。`tasks/` 顶层只保留 `PROGRESS.md` / `lessons.md` / `_archive/`，遵循全局 CLAUDE.md "`tasks/` 目录规范"
- **PR 标题**：`feat(menu-bar): ...` / `fix(hips): ...` / `docs(adr): ...`
- **commit 范围**：`menu-bar` / `hips` / `settings` / `history` / `debug` / `onboarding` / `toast` / `ipc` / `infra`

---

## 关键文档导航

- 产品需求：`docs/requirements/sieve-gui-macos-prd-v1.0.md`
- 系统架构：[`docs/design/architecture.md`](docs/design/architecture.md)
- IPC 协议：[`docs/api/ipc-protocol.md`](docs/api/ipc-protocol.md)
- ADR 索引：[`docs/design/adr/INDEX.md`](docs/design/adr/INDEX.md)
- SPEC 索引：[`docs/specs/INDEX.md`](docs/specs/INDEX.md)
- 上游引用：[`docs/external/upstream-references.md`](docs/external/upstream-references.md)
- 开发指南：[`docs/guides/development.md`](docs/guides/development.md)
- 发布指南：[`docs/guides/deployment.md`](docs/guides/deployment.md)
- 当前进度真实源：`tasks/PROGRESS.md`
- 经验沉淀：`tasks/lessons.md`
