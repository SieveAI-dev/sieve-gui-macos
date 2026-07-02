# 开发指南

> Version: v1.0 — 2026-05-02
> Status: Stable
> Owner: SieveAI

---

## 0. 目标读者

- 新加入本仓库、需要在本机跑起来 GUI 的工程师
- 维护者（避免每次重装 Mac 再翻一次配置）

---

## 1. 前置条件

| 工具 | 版本 | 用途 |
|------|-----|------|
| macOS | 13 Ventura+ | 平台目标 |
| Xcode | 15+ | 主 IDE，含 Swift 5.9 toolchain |
| swiftformat | 0.52+ | 代码格式（CI 强制） |
| Sparkle CLI | 2.x | 生成 appcast |
| `sieve` daemon | 与本仓库 protocol_version 匹配 | 完整端到端联调时需要 |
| `gpg` / `codesign` | macOS 自带 | notarization 流程 |

---

## 2. 第一次跑起来

```bash
# 1. clone
git clone <repo-url> sieve-gui-macos
cd sieve-gui-macos

# 2. （可选）装 swiftformat（CI 用）
brew install swiftformat

# 3. 打开工程
open SieveGUI.xcodeproj
# 或：xed .

# 4. Xcode 选 SieveGUI scheme，Cmd+R 运行
```

首次启动会进入 Onboarding。如果本机没装 daemon，进入 disconnected 模式：

- 菜单栏图标变红 ⚠
- Onboarding step 2 显示 daemon 未运行

无真 daemon 时的 UI/协议调试走测试用的 `MockDaemonHarness`（见 §5），它在测试进程内起一个临时 IPC 端点并按脚本推送 HIPS 请求 / `notify_status_bar`，无需另起进程。

---

## 3. 项目结构

简化版：

```
SieveGUI.xcodeproj
Sources/
├── App/
│   ├── SieveGUIApp.swift           ← @main, 注册 Window scene
│   ├── AppDelegate.swift
│   └── AppState.swift              ← @Observable 单例
├── Features/
│   ├── MenuBar/                    ← 菜单栏 + Quick Menu
│   ├── Hips/                       ← HIPS 弹窗
│   ├── Settings/                   ← 设置 6 个 Tab
│   ├── History/                    ← 历史窗口
│   ├── Debug/                      ← 调试 4 个 Tab
│   ├── Onboarding/                 ← 引导
│   └── Toast/                      ← 状态栏 Toast
├── Services/
│   ├── IPC/                        ← IPCClient, JSON-RPC codec
│   ├── AuditDB/                    ← SQLite.swift 包装
│   ├── TouchID/                    ← LAContext 解锁会话
│   ├── Notifications/              ← UNUserNotificationCenter
│   ├── Diagnostic/                 ← 诊断包导出
│   └── Sparkle/                    ← Sparkle 包装
├── Models/
│   ├── HipsRequest.swift
│   ├── HitSummary.swift
│   ├── DaemonStatus.swift
│   └── ...
├── UI/
│   ├── Components/
│   │   ├── MaskedField.swift       ← 唯一允许渲染敏感字段的组件
│   │   ├── CountdownBar.swift
│   │   ├── SeverityChip.swift
│   │   └── ...
│   └── Theme/
│       ├── Tokens.swift
│       └── Typography.swift
└── Resources/
    ├── Localizable.xcstrings       ← String Catalog（zh/en）
    ├── Assets.xcassets
    └── Info.plist                  ← LSUIElement = YES
Tests/SieveGUITests/
├── IPC/
├── Hips/
├── MockDaemonHarness.swift         ← 测试内 IPC mock 端点
└── ...
docs/                               ← 你正在读
```

每个文件 < 400 行；超过即拆分。

---

## 4. 跑测试

```bash
# 逻辑单测（Core 库 + 纳入 Core 的 Features 逻辑）——命令行真实源
swift test

# UI / Features 层编译验证（swift test 按 Package.swift exclude 跳过 UI，必须经 xcodebuild build）
xcodebuild build \
  -project SieveGUI.xcodeproj \
  -scheme SieveGUI \
  -destination 'platform=macOS'
```

> `Tests/SieveGUITests` 的用例统一 `@testable import SieveGUICore`（`Package.swift` 的 SPM
> 库名），是 SPM-only 设计，由 `swift test` 执行。本工程当前刻意不为 Core 建独立 framework
> target（避免 `project.yml` 与 `Package.swift` 两份源清单同步漂移），故 Xcode 工程内无
> `SieveGUICore` module，scheme 不配置 test action，`Cmd+U` / `xcodebuild test` 不适用——这是
> deliberate tradeoff，非技术不可能。备选演进路径与排除理由详见 `project.yml` 顶部注释。

测试框架：[swift-testing](https://github.com/apple/swift-testing)（`@Test` macro）。

关键测试目录：
- `Tests/SieveGUITests/IPC/` — JSON-RPC 编解码、重连、inflight 队列
- `Tests/SieveGUITests/Hips/` — Remember 渲染约束、主按钮位置、倒计时阶段切换、防误点
- `Tests/SieveGUITests/AuditDB/` — schema 升级 fail-soft、查询性能
- `Tests/SieveGUITests/MockDaemonHarness.swift` — 测试内 IPC mock 端点，注入握手 / 推送 / 异常场景

---

## 5. MockDaemonHarness 用法

`Tests/SieveGUITests/MockDaemonHarness.swift` 在测试进程内起一个临时 IPC 端点，模拟 daemon 的握手与推送，供 IPCClient 与各 Feature ViewModel 做集成测试，无需另起进程或依赖真 daemon。

典型用法（在测试中）：

```swift
let harness = MockDaemonHarness()
try await harness.start()                       // 临时 socket，连接后自动发 sieve.hello
await harness.sendRequestDecision(.inCr05)      // 推单 issue HIPS 请求
await harness.sendRequestDecision(.merged)      // 推多 issue 合并
await harness.sendStatusBarNotify(.outboundRedacted)
await harness.disconnect()                       // 模拟失联
```

覆盖的场景：握手成功 / 协议版本不识别 / 重连丢 inflight / 地址替换（IN-CR-01）/ 多 issue 合并 / 失联后兜底。具体可注入的场景见 `MockDaemonHarness` 的公开方法。

---

## 6. 联调真 daemon

```bash
# 1. 装 daemon（参考上游仓库 README；可从源码构建，一键安装渠道 coming soon）

# 2. 跑 setup（按需选 agent：claude / openclaw / hermes / codex）
sieve setup

# 3. 验证 daemon 健康
sieve doctor

# 4. 在 Xcode 跑 GUI
```

注意：daemon 由 launchd 管，不需要手动启动。如果 IPC 失联，跑 `launchctl list | grep sieve` 看服务状态。

---

## 7. 编码规范快速参考

详见 [`../../CLAUDE.md`](../../CLAUDE.md)。要点：

- Swift 5.9+，`-warnings-as-errors`
- 异步：`async/await`
- UI 状态：每个模块内 `@State` / `@Observable` / `@Published` 三选一一致
- 不在 SwiftUI View 里写业务逻辑
- 敏感字段必须走 `MaskedField`，禁止裸 `Text(...)`
- 用户可见文案走 String Catalogs

提交前跑：

```bash
swiftformat Sources Tests
swiftformat Sources Tests --lint  # CI 强制（路径须在选项前，swiftformat 0.61.x 否则会把路径当 --lint 的值）
```

---

## 8. 调试技巧

### 8.1 看 GUI 自己的日志

```bash
tail -f ~/.sieve/gui.log | jq .
```

格式见 [`data-model.md §4`](../design/data-model.md#4-sievegui-log)。

### 8.2 看 IPC 流量

调试窗口 → IPC 监视 Tab。或者在代码里临时打开：

```swift
IPCClient.shared.enableTraceLogging = true
```

trace log 写到 `~/.sieve/gui.log`，scope 为 `ipc`。**不**包含 params 详情（避免泄密）。

### 8.3 复现某个 audit 事件

调试窗口 → 实时事件 Tab → 右键事件 → "在历史中定位"。
或者：调试窗口 → 规则评估 Tab，粘贴可疑文本，按"评估"。

### 8.4 模拟 Touch ID 失败

```bash
# 临时关掉 Touch ID（设置 → 触控 ID → 解除指纹），或：
defaults write com.sieve.gui kForceFakeTouchIDFailure -bool YES
```

记得调试完关：

```bash
defaults delete com.sieve.gui kForceFakeTouchIDFailure
```

### 8.5 强制清空 UserDefaults

```bash
defaults delete com.sieve.gui
# 然后重启 GUI 会重新进入 Onboarding
```

---

## 9. 常见问题

### Q: 启动后菜单栏没图标？
A: 确认 `Info.plist` 里 `LSUIElement = YES`；确认 Xcode scheme 选的是 SieveGUI 而不是测试 target。

### Q: HIPS 弹窗没在全屏应用上方？
A: 检查 NSPanel 配置是否含 `.canJoinAllSpaces` 和 `.fullScreenAuxiliary`。如果 macOS 行为变了（Apple 偶尔改），降级到系统通知。

### Q: 改了 String Catalog 没生效？
A: Cmd+Shift+K 清理 build，重启 Xcode。String Catalog 的 build phase 偶尔不增量更新。

### Q: 联调真 daemon 时报 "Address already in use"？
A: 上次的 daemon 没退干净，或残留 socket 文件。`rm -f ~/.sieve/ipc.sock` 后重启 daemon。

---

## 10. CI / 提交流程

- 本地 `swiftformat --lint` 通过
- `swift test` 通过；动了 `Sources/UI` / `Sources/Features` 再跑 `xcodebuild build`
- commit message：Conventional Commits（`feat(menu-bar): ...` / `fix(hips): ...` / `docs(spec-002): ...`）
- 修改 IPC 相关代码 → 同步更新 `docs/api/ipc-protocol.md` + `docs/specs/SPEC-008-ipc-client.md`
- 修改 SPEC 描述行为时 → 同步更新对应代码 + 测试

PR 模板见 `.github/pull_request_template.md`（待建）。
