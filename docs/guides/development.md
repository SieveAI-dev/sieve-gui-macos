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
| swift-format | 0.50+ | 代码格式（CI 强制） |
| Sparkle CLI | 2.x | 生成 appcast |
| `sieve` daemon | 与本仓库 protocol_version 匹配 | 完整端到端联调时需要 |
| `gpg` / `codesign` | macOS 自带 | notarization 流程 |

可选（mock 调试用，无需真 daemon）：

| 工具 | 用途 |
|------|------|
| `swift run sieve-gui-mock-daemon` | 本仓库内置的 mock daemon，模拟 IPC 推送 |

---

## 2. 第一次跑起来

```bash
# 1. clone
git clone <repo-url> sieve-gui-macos
cd sieve-gui-macos

# 2. （可选）装 SwiftLint / swift-format（CI 用）
brew install swift-format

# 3. 打开工程
open SieveGUI.xcodeproj
# 或：xed .

# 4. Xcode 选 SieveGUI scheme，Cmd+R 运行
```

首次启动会进入 Onboarding。如果本机没装 daemon，进入 disconnected 模式：

- 菜单栏图标变红 ⚠
- Onboarding step 2 显示 daemon 未运行

切到 mock daemon（不需要真 daemon）：

```bash
# 在另一个终端
swift run sieve-gui-mock-daemon
```

mock 会在 `~/.sieve/ipc.sock` 启动一个假 daemon，按预设脚本推送 HIPS 请求 / event_notify，便于 UI 调试。

---

## 3. 项目结构

详见 [ADR-009](../design/adr/ADR-009-project-layout-single-target.md)。简化版：

```
SieveGUI.xcodeproj
SieveGUI/
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
│   ├── Diagnostics/                ← 诊断包导出
│   └── Updates/                    ← Sparkle 包装
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
SieveGUITests/
├── IPC/
├── Hips/
└── ...
mock/
└── sieve-gui-mock-daemon/          ← Swift Package, executable target
docs/                               ← 你正在读
```

每个文件 < 400 行；超过即拆分。

---

## 4. 跑测试

```bash
# 全部测试
xcodebuild test \
  -project SieveGUI.xcodeproj \
  -scheme SieveGUI \
  -destination 'platform=macOS'

# 或在 Xcode：Cmd+U
```

测试框架：[swift-testing](https://github.com/apple/swift-testing)（`@Test` macro）。

关键测试目录：
- `SieveGUITests/IPC/` — JSON-RPC 编解码、重连、inflight 队列
- `SieveGUITests/Hips/` — Remember 渲染约束、主按钮位置、倒计时阶段切换、防误点
- `SieveGUITests/AuditDB/` — schema 升级 fail-soft、查询性能
- `SieveGUITests/Mock/MockDaemon.swift` — 复用 mock daemon 注入异常

---

## 5. mock daemon 用法

`mock/sieve-gui-mock-daemon` 是一个独立 Swift Package，跑起来后在 `~/.sieve/ipc.sock` 监听，按命令行参数推送预设消息。

```bash
# 默认脚本：5 秒后推一条 IN-CR-05 单 issue HIPS 请求
swift run sieve-gui-mock-daemon

# 推 IN-CR-01（地址替换）
swift run sieve-gui-mock-daemon --scenario address-substitution

# 推多 issue 合并
swift run sieve-gui-mock-daemon --scenario merged

# 模拟失联（建立连接后 5s 关闭）
swift run sieve-gui-mock-daemon --scenario disconnect-after-5s

# 模拟协议版本不识别
swift run sieve-gui-mock-daemon --protocol-version v99

# 自定义脚本（YAML/JSON）
swift run sieve-gui-mock-daemon --script my-script.yaml
```

预设场景列表：见 `mock/sieve-gui-mock-daemon/scenarios/`。

---

## 6. 联调真 daemon

```bash
# 1. 装 daemon（参考上游仓库 README）
brew install sieve

# 2. 跑 setup
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
swift-format format -i -r SieveGUI/
swift-format lint -r SieveGUI/  # CI 强制
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
A: 这是 OQ-G-01。检查 NSPanel 配置是否含 `.canJoinAllSpaces` 和 `.fullScreenAuxiliary`。如果 macOS 行为变了（Apple 偶尔改），降级到系统通知。

### Q: 改了 String Catalog 没生效？
A: Cmd+Shift+K 清理 build，重启 Xcode。String Catalog 的 build phase 偶尔不增量更新。

### Q: `swift run sieve-gui-mock-daemon` 报 "Address already in use"？
A: 上次的 mock 没退干净。`rm -f ~/.sieve/ipc.sock` 后重跑。

---

## 10. CI / 提交流程

- 本地 `swift-format lint` 通过
- `xcodebuild test` 通过
- commit message：Conventional Commits（`feat(menu-bar): ...` / `fix(hips): ...` / `docs(spec-002): ...`）
- 修改 IPC 相关代码 → 同步更新 `docs/api/ipc-protocol.md` + `docs/specs/SPEC-008-ipc-client.md`
- 修改 SPEC 描述行为时 → 同步更新对应代码 + 测试

PR 模板见 `.github/pull_request_template.md`（待建）。
