# 术语表

> 本仓库与上游 daemon 仓库共用术语集合。本文件只列出在 GUI 文档中**实际出现**的术语。
> 不在此列的上游术语，请见 [`external/upstream-references.md`](external/upstream-references.md) 中转到上游公开 SPEC。

---

## A

### accessory app
macOS App 的一种运行模式，由 `Info.plist` 中 `LSUIElement = true` 决定。无 Dock 图标、无主菜单条；只通过 NSStatusItem（菜单栏）和窗口与用户交互。Sieve GUI 是 accessory app。

### audit.db
daemon 写、GUI 只读的 SQLite 数据库，存所有规则命中事件（不存原始 prompt 字节）。路径 `~/.sieve/audit.db`。schema 由 daemon 主导。

### AutoRedact
处置类型之一：daemon 检测到出站匹配后，**自动改写**请求 body（如把 API key 替换为 `[REDACTED]`），不弹窗、不阻断。GUI 收 `notify_status_bar` 后只显示 Toast。

---

## C

### Capsule
SwiftUI 形状之一（圆角矩形两端为半圆）。HIPS 弹窗倒计时进度条用 `Capsule().fill(...)` 实现。

### chain_id
EIP-155 定义的以太坊兼容链 ID（1 = Ethereum mainnet、56 = BSC 等）。HIPS 弹窗 IN-CR-05 详情卡显示。

### Critical
规则严重度 enum 之一：`critical | high | medium | low`。Critical 规则的 GuiPopup 类即便用户暂停也仍会弹窗。

### critical_lock
规则保护机制：被 lock 的规则**禁止**`allow_remember`、禁止用户改 `timeout_seconds` 和 `default_on_timeout`。GUI 侧的执行职责见 [`SPEC-002`](specs/SPEC-002-hips-popup-window.md)。

---

## D

### daemon
本仓库语境下专指 Sieve daemon —— 上游 Rust 仓库的常驻进程，监听 `127.0.0.1:11453`，做检测、规则匹配、SSE 解析、灰名单写入、审计日志写入。

### default_on_timeout
HIPS 弹窗超时后 daemon 的处置：`Block | Allow`。GUI 失联或弹窗未答时由 daemon fail-closed 兜底，GUI 不参与决策。

### direction
请求方向：`outbound | inbound`。出站 = 用户/Agent 发给 LLM；入站 = LLM 回给用户。

### disposition
规则的处置类型：`AutoRedact | StatusBar | GuiPopup | HookTerminal`。GUI 只对 `GuiPopup` 弹窗，对 `AutoRedact / StatusBar` 显示 Toast。

### DispatchSource
GCD 的文件监视源（`DispatchSource.makeFileSystemObjectSource`）。GUI 用它监听 `audit.db` 变化做增量刷新。

---

## E

### evidence_meta
audit.db 中的字段：命中证据的元数据（`{"len": 412, "prefix_hash": "...", ...}`）。**不含原始字节**——与「不存原文」的产品承诺一致。

---

## F

### fail-closed
失败时默认拒绝。GUI 失联、弹窗超时、协议不识别 → 全部走拒绝分支。GUI 自身不做"假装健康"的兜底。

### fingerprint
规则命中的去重键，由 daemon 计算。形如 `7a3f...e9c2`。Quick Menu / 历史 / 灰名单都展示 fingerprint 短前缀。

### floating panel
`NSPanel` 的一种配置：`window.level = .floating`，浮在普通窗口之上。HIPS 弹窗用此模式 + `.canJoinAllSpaces` + `.fullScreenAuxiliary` 实现"全屏应用上方也能浮现"。

---

## G

### graylist（灰名单）
用户对某个 fingerprint 的"永久允许"决定。存在 daemon 端 `~/.sieve/decisions/`。GUI 在设置面板提供查看 + 删除入口（不直接编辑文件）。

### GuiPopup
处置类型之一：触发 HIPS 弹窗，等用户答复后再决定 allow / deny。

---

## H

### hardened runtime
macOS App 签名的一种模式：限制 dyld inject、不允许未签名代码加载。Sieve GUI 必须开启。

### hello
IPC 握手消息：daemon 连上后第一条 `sieve.hello`，含 `protocol_version` / `daemon_version` / `paused` / `preset`。

### HIPS
Host-based Intrusion Prevention System。本项目特指那个**抢占焦点的浮窗**——daemon 检测到危险动作时让用户做出 allow/deny 决定。

### HookTerminal
处置类型之一：daemon 通知 Claude Code Hook 在终端阻止动作（不走 GUI）。GUI 不渲染此类事件，但调试 Tab 可以看到。

### hold
菜单栏图标状态之一：当前有 GuiPopup 类请求在等用户回复，daemon 在 hold SSE 流。图标显示红色 ● + 倒计时数字。

---

## I

### IPC
进程间通信。本项目特指 GUI ↔ daemon 之间的 Unix Domain Socket + JSON-RPC 2.0 通道。详见 [`api/ipc-protocol.md`](api/ipc-protocol.md)。

### inflight
IPC 客户端术语：已发送 request 但还没收到 response 的消息集合。重连时需要同 request_id 重发。

### issue
HIPS 弹窗中的单条命中。多 issue 弹窗 = daemon 把同一 request_id 下多个规则命中合并成一个 `request_decision`。

---

## L

### LAContext
`LocalAuthentication.framework` 的认证上下文。Sieve GUI 用它做 Touch ID 解锁敏感字段。

### Levenshtein 距离
两个字符串的编辑距离。HIPS 弹窗 IN-CR-01 详情卡用它显示原地址 vs 替换地址的差异程度。

### LSUIElement
`Info.plist` 键。设为 `true` 让 App 不出现在 Dock，作为 accessory app 运行。

---

## M

### merged
HIPS 弹窗多 issue 模式标记。`request_decision.params.merged == true` 时 GUI 渲染折叠列表 + 不同的按钮组合。

---

## N

### NSStatusItem
AppKit 提供的菜单栏项 API。Sieve GUI 用它显示状态图标 + Quick Menu。

### normal / warning / hold / paused / disconnected
菜单栏图标 5 种状态。详见 [`SPEC-001`](specs/SPEC-001-menu-bar-and-quick-menu.md) §2。

### notarization
Apple 的二次安全审核流程。所有发布版本必须 notarize 才能在他人 Mac 上一键打开（不需要右键 → 打开绕过 Gatekeeper）。

---

## O

### Onboarding
首次运行的引导流程。6 步，详见 [`SPEC-006`](specs/SPEC-006-onboarding-flow.md)。

### outbound / inbound
见 `direction`。

---

## P

### Permit2
Uniswap 的 ERC-20 授权标准。HIPS 弹窗 IN-CR-05 检测的危险信号之一（`deadline=0` + 无限 amount = 经典钓鱼模式）。

### preset
检测预设：`Strict | Standard | Relaxed | Custom`。影响 daemon 的超时倍率和某些规则的 disposition。设置面板可切。

### protocol_version
IPC 协议版本号。当前 `v2`（白名单仅 `v2`）。GUI 不识别版本号 → 进入 disconnected。

---

## Q

### Quick Menu
点击菜单栏图标弹出的 popover，显示状态、最近命中、暂停按钮、设置/历史/调试入口。

---

## R

### recommendation
HIPS 弹窗的 daemon 推荐字段：`{decision, confidence, reason}`。GUI 渲染推荐栏 + 决定主按钮位置。

### redact
脱敏。出站 AutoRedact 是 daemon 改写 body；GUI 在历史窗口默认 mask 显示也叫 redact。

### Remember
HIPS 弹窗 checkbox："不再询问此模式"。勾选 + allow → daemon 写入灰名单。`allow_remember == false` 时 GUI **禁止渲染**此 checkbox。

### request_decision
daemon → GUI 的 IPC 方法：要求弹窗。

### request_decision_canceled
daemon → GUI 的 IPC notification：已经发出但未答的 request_id 因超时/取消被废弃。

### request_id
单次 HIPS 决策的唯一标识，UUID 格式。

---

## S

### Sandbox 评估器
调试窗口"规则评估"Tab 的功能：用户粘贴可疑文本，daemon 在沙箱模式跑规则匹配，返回结果。**不写 audit.db**。

### sieve doctor
daemon 仓库提供的 CLI 命令，5 项健康检查。Onboarding step 2 调用。详见上游 SPEC-003（[`external/upstream-references.md`](external/upstream-references.md)）。

### sieve setup
daemon 仓库的 CLI 命令，自动配置环境（`ANTHROPIC_BASE_URL`、Hook 注册、launchd 服务）。Onboarding 修复时调用。

### Sparkle
macOS App 的开源自动更新框架。Sieve GUI 用它走 EdDSA 签名 + appcast XML。

### SMAppService
macOS 13+ 的 LoginItem 注册 API（替换老的 SMLoginItemSetEnabled）。Onboarding step 4 调用。

### SSE
Server-Sent Events。LLM 响应的流式协议。daemon 在 SSE 流上做检测和 hold。GUI 不解 SSE。

### StatusBar
处置类型之一：daemon 改写 body 顺便要求 GUI 在状态栏显示标记（不弹窗）。

---

## T

### tool_use
Anthropic API 的工具调用消息块。HIPS 弹窗 IN-CR-05 检测危险的 tool_use（如 `signTransaction` + `deadline=0`）。

### Touch ID
macOS 的指纹认证。GUI 用它解锁历史窗口的敏感字段查看（5 分钟解锁会话）。

### typed_data
EIP-712 结构化签名的数据格式。HIPS 弹窗 IN-CR-05 详情卡渲染。

---

## U

### UDS
Unix Domain Socket。本项目 IPC 通道。
