# CLAUDE.md — Sieve GUI for macOS

本文件给 Claude / AI 助手用。全局规则继承 `~/.claude/CLAUDE.md`，本文件只写本仓库特有约束。

---

## 一句话项目定位

Sieve GUI 是 [Sieve daemon](#上游-daemon) 的 native macOS 守门人壳：常驻菜单栏、HIPS 弹窗、读 audit.db 给历史。**daemon 做检测，GUI 只做交互。**

受支持的上游 agent：Claude Code / OpenClaw / Hermes / Codex CLI。

---

## 技术栈（硬约束，不可更换）

- **macOS 13+ / SwiftUI / Combine / SQLite.swift / Network.framework**
- 第三方依赖白名单：`SQLite.swift`、`Sparkle`。其他一律 reject。
- **不引入** Electron / Tauri / Catalyst / SwiftCrossUI / Objective-C++ / RxSwift。
- 决策依据：Phase 1 GUI 锁定 SwiftUI native-only 技术栈，独立 git 仓库；不引入跨平台/混合栈是为保证 native 体验与最小依赖面。

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
- IPC 行为由 `MockDaemonHarness` 测试 fixture 覆盖做单元测试；端到端联调直接连真 sieve daemon（`~/.sieve/ipc.sock`），daemon 不在时 GUI 进入 disconnected。

## 代码结构概览

```
Sources/
├── App/         入口（@main、AppDelegate、生命周期）
├── Models/      Codable IPC payload + 领域类型（HipsRequest / DecisionResponse / HitSummary / UserSettings …）
├── Services/    无 UI 副作用的服务层
│   ├── IPC/         Unix Socket 客户端、JSON-RPC 2.0、InflightQueue、协议版本握手
│   ├── AuditDB/     SQLite.swift 只读 audit.db
│   ├── Logger/      GUI 自身日志（不复用 daemon 通道）
│   ├── Telemetry/   Debug 用实时事件环形缓冲（RingBuffers）——GUI 无任何遥测上报
│   ├── Sparkle/     自动更新（决策路径外）
│   ├── Notifications/ 通知中心封装
│   ├── TouchID/     LocalAuthentication 包装
│   └── Diagnostic/  脱敏诊断包导出
├── Features/    每个面是一个文件夹：HIPS / MenuBar / History / Settings / Debug / Onboarding / Toast
│                History 有独立 ViewModel（HistoryWindowViewModel，ObservableObject）；
│                其余 Feature 的状态逻辑在 Manager/Controller 或 View 内（无独立 ViewModel）
├── UI/          跨 Feature 复用的 SwiftUI 组件（含 MaskedField 等红线组件）
└── Resources/   xcstrings、图标
```

数据流单向：`daemon → IPC → Models → Feature 状态层（Manager/ViewModel）→ SwiftUI View`；用户答复反向 `View → 状态层 → IPC.send → daemon`。决策路径**不**经过 Services/Sparkle / Notifications。

理解任何 Feature 时，先读其状态层（HIPS 是 `HipsPanelManager`、History 是 `HistoryWindowViewModel`、菜单栏是 `MenuBarController`）摸状态机，再读对应 SPEC 对照红线，最后看 View。

## 文档体系

本仓库严格遵循全局 DOCS-STANDARD v2.1（见 [`docs/DOCS-STANDARD.md`](docs/DOCS-STANDARD.md)）。所有 ADR 一律私有，公开仓不含 ADR 文件、不引用 ADR 编号。

- 修改任何**功能代码**前，先读对应模块的 SPEC（`docs/specs/SPEC-NNN-*.md`）
- 修改任何**架构相关**代码前，先读 [`docs/design/architecture.md`](docs/design/architecture.md)
- 修改任何与 daemon 交互的代码前，先读 [`docs/api/ipc-protocol.md`](docs/api/ipc-protocol.md)

## 上游 daemon

本仓库的所有 IPC 行为、规则字段、`allow_remember` 计算逻辑都由 daemon 决定。
**GUI 不发明协议字段，不改写 daemon 推送的值。**

上游契约清单见 [`docs/external/upstream-references.md`](docs/external/upstream-references.md)。
任何 IPC 字段或行为变更必须**两个仓库同时改 SPEC + 协议版本号**。

---

## 硬约束（违反 = reject PR）

关键几条：

1. **`allow_remember == false` 时，HIPS 弹窗禁止渲染 Remember checkbox**（不允许灰显代替）。这是 daemon「Allow Remember 四道防线」中 GUI 承担的第 2 道（UI 不渲染 Remember 控件）——GUI 无条件信任 daemon 计算出的 `allow_remember`，字段为 false 即不渲染；GUI 另在编码层强制 `remember=false`（第 3 道，`completeDecision` 的 `safeRemember`）。四道防线权威定义见 SPEC-005 §6.1.1。
2. **GUI 决策路径不联网**。Sparkle 检查更新和 external link 例外，且二者不影响 HIPS 弹窗。
3. **不存储原始 prompt / 命中片段**。daemon 推送的 evidence 只在内存中持有，弹窗关闭即丢弃。
4. **HIPS 主按钮在 `recommendation` 缺失或 `confidence != high` 时永远是「拒绝」**。**Return 恒绑拒绝**：允许类按钮在任何组合下永不挂 `keyboardShortcut`（键盘无法触发允许），由 `HipsFooterPolicy.bindsReturnKey` 策略驱动、矩阵测试锚定——非"默认到拒绝"的弱约定。
5. **协议版本不识别 → disconnected**。不允许向后兼容字段嗅探。
6. **菜单栏状态以 `sieve.hello` 实际握手为准**，不允许"假装健康"。
7. **导出诊断包默认脱敏**，不依赖用户阅读条款。
8. **写文件操作走 atomic rename**（preset 缓存 / 用户设置 / GUI log）。
9. **Critical allow 决策放行前强制「人在场」认证**（`CriticalAllowGate` + `TouchIDService.authenticateForCriticalDecision`，含系统密码回退）。认证失败/取消降级 deny，不建解锁会话；**无任何跳过开关或环境变量**。
10. **HIPS 字段脱敏解锁与 History 会话完全隔离**（`HipsFieldUnlock` 上收 `AppState.hipsFieldUnlock`，绑定 `request_id` 仅当前弹窗有效，认证不建会话；决策提交/关窗/hold 归零/锁屏/会话过期任一即失效）。双向隔离，见 SPEC-002 §4.4。

---

## 编码规范增量（在全局 CLAUDE.md 之上）

### Swift

- Swift 5.9+，开启 `-warnings-as-errors`
- 文件顶部不写 `// Created by ...` 自动注释（已在 Xcode 模板里关掉）
- 所有 IPC 消息走 `Codable` 结构体，禁止 `[String: Any]` 透传
- 异步：`async/await` 优先，`Task` 取消必须传播
- UI 状态：`@State` + `Combine` `ObservableObject`/`@Published`（deploymentTarget 为 macOS 13，
  `@Observable` 是 macOS 14+ API，**不可用**），同一模块内保持一致
- 不在 SwiftUI View 里写业务逻辑；共享状态放 ObservableObject（AppState/Manager/ViewModel）

### 字符串

- 用户可见文案一律走 String Catalogs（`Localizable.xcstrings`）
- 调试日志可硬编码英文，但**不要**机翻中文
- 敏感字段（地址、密钥、tool input）的渲染必须走 `MaskedField` 组件，禁止裸 `Text(...)`

### 测试

- 单元测试：`swift testing` 框架（`@Test` macro）
- IPC 客户端走 `MockDaemonHarness` 测试 fixture（见 [`docs/guides/development.md`](docs/guides/development.md)）
- HIPS 弹窗的关键约束（Remember 渲染 / 主按钮位置 / 倒计时阶段切换）必须有快照/行为测试

### 文件组织

- 单 target，按模块分文件夹（单 App target + 命令行可测的 Core 库双轨布局）
- 文件 > 400 行 = 拆分信号
- 一个 `View` / `Model` / `Service` 一个文件，类名与文件名一致

---

## 工作流增量

- **进度真实源**：项目进度与经验沉淀不在公开仓维护，本公开仓不保留内部进度细节
- **PR 标题**：`feat(menu-bar): ...` / `fix(hips): ...` / `docs(spec): ...`
- **commit 范围**：`menu-bar` / `hips` / `settings` / `history` / `debug` / `onboarding` / `toast` / `ipc` / `infra`

---

## 关键文档导航

- 系统架构：[`docs/design/architecture.md`](docs/design/architecture.md)
- IPC 协议：[`docs/api/ipc-protocol.md`](docs/api/ipc-protocol.md)
- SPEC 索引：[`docs/specs/INDEX.md`](docs/specs/INDEX.md)
- 上游引用：[`docs/external/upstream-references.md`](docs/external/upstream-references.md)
- 开发指南：[`docs/guides/development.md`](docs/guides/development.md)
- 发布指南：[`docs/guides/deployment.md`](docs/guides/deployment.md)
