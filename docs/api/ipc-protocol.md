# IPC 协议参考 — GUI 实现注解

> Version: v2.1 — 2026-05-07
> Status: Stable
> Owner: SieveAI
> **权威协议规格**：[upstream `SPEC-005-ipc-protocol.md`](../external/upstream-references.md#spec-005ipc-protocol)（daemon 仓库 `docs/specs/SPEC-005-ipc-protocol.md`）
> 上游 ADR：[ADR-013](../external/upstream-references.md#adr-013ipc-protocol) · [ADR-026](../external/upstream-references.md#adr-026port-based-listener-routingunix-style-改造-1) · [ADR-028](../external/upstream-references.md#adr-028ipc-protocol-neutralizationunix-style-改造-3) · [SPEC-002](../external/upstream-references.md#spec-002hips-popup-behavior)
> GUI 实现端：[SPEC-008](../specs/SPEC-008-ipc-client.md)

---

## 0. 文档定位

> ⚠️ **本文件不再定义 schema 字段。**

所有方法名、字段名、枚举值、错误码、握手时序的定义全部在 **SPEC-005**（daemon 仓库 `docs/specs/SPEC-005-ipc-protocol.md`），这是双仓库唯一权威源。本文件只描述 **GUI 实现端的本地行为**：

- GUI 端 Codable 结构与 wire schema 的映射约定
- 解析容错策略（未知字段、未知枚举值、超时降级）
- IPC 客户端状态机（disconnected ↔ connecting ↔ handshaking ↔ connected ↔ retrying）
- UI 状态机映射（菜单栏指示灯、disconnected 横幅、HIPS 弹窗排队）
- 重连与超时策略（GUI 端独有，不在 SPEC-005 范围内）

任何 wire 协议层面的疑问 → 直接去 SPEC-005，不要在本文件二次定义。

---

## 1. 协议版本

GUI 当前实现 SPEC-005 v2 协议（`protocol_version = "v2"`）。GUI 白名单：`["v2"]`，收到任何其他值立即关闭连接、UI 引导用户升级。

不允许"嗅探未知字段做向后兼容"——版本不匹配 = 不通信，没有中间态。

---

## 2. 连接与握手（GUI 端实现）

### 2.1 socket 校验

GUI 连接 `~/.sieve/ipc.sock` 前必须校验：

| 项 | 期望 | 不符合时 GUI 行为 |
|---|---|---|
| 文件存在 | 是 | 进入 disconnected，提示"daemon 未运行" |
| 父目录权限 | `0700` | 进入 disconnected，提示"权限异常，运行 sieve doctor" |
| socket 文件权限 | `0600` | 同上 |
| 文件 owner | 当前用户 UID | 拒连，提示"用户不匹配" |

### 2.2 握手时序（GUI 视角）

1. GUI connect socket → 立即启动 5 秒 handshake timer
2. 收到第一条消息：
   - 是 `sieve.hello` notification → 校验 `protocol_version`，写入 AppState（`paused` / `preset` / `daemon_version`），cancel timer，标记 connected
   - 是其他任何消息 → 视为协议违规，关闭连接，进入 retrying
3. timer 超时未收到 hello → 关闭连接，进入 retrying
4. `protocol_version` 不在白名单 → 关闭连接，进入 disconnected，UI 引导升级（**不重连**，避免 daemon-不会自愈的死循环）

### 2.3 重连退避

| 次数 | 间隔 |
|---|---|
| 1 | 1 s |
| 2 | 2 s |
| 3 | 5 s |
| 4 | 10 s |
| ≥5 | 30 s（持续） |

任何成功握手 → 重置退避计数。

### 2.4 心跳超时

- GUI 内部维护 `lastReceivedAt`，所有入站消息（含 heartbeat、业务消息）都刷新此时间
- 30 秒内 `lastReceivedAt` 未刷新 → 关闭连接，进入 retrying
- daemon 心跳周期是 25 秒（SPEC-005 §4），GUI 30 秒超时给 5 秒缓冲

---

## 3. Codable 命名约定

GUI 用 Swift `Codable`。所有 IPC payload 结构遵循：

- Swift property 用 camelCase（语言约定）
- `CodingKeys` 显式映射到 wire 上的 snake_case
- 严禁 `[String: Any]` 透传 IPC 字段（CLAUDE.md 硬约束）

示例：

```swift
struct DecisionRequestParams: Codable {
    let requestId: UUID
    let allowRemember: Bool
    let timeoutSeconds: UInt32

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case allowRemember = "allow_remember"
        case timeoutSeconds = "timeout_seconds"
    }
}
```

枚举映射：所有 wire 枚举（severity / direction / disposition / preset_mode 等）的 raw value **必须用 SPEC-005 §5 的小写 snake_case 字面量**，禁止 PascalCase 化为符合 Swift 风格的 raw value。

```swift
enum Severity: String, Codable {
    case critical, high, medium, low
}

enum PresetMode: String, Codable {
    case strict, standard, relaxed, custom
    // ⚠️ 不要写 "Default"——SPEC-005 v2 把 "default" 重命名为 "standard"
}
```

---

## 4. 解析容错策略

### 4.1 未知字段

JSONDecoder 默认忽略未知 key（Swift Codable 行为符合 SPEC-005 §13.2）。**不要**为了"严格校验"启用任何 strict-decoder 模式。

### 4.2 未知枚举值

每个 wire 枚举都要在 GUI 端有 `unknown` 兜底分支：

```swift
enum NotifyKind: String, Codable {
    case sequenceHit = "sequence_hit"
    case outboundRedacted = "outbound_redacted"
    case hookTerminal = "hook_terminal"
    case userRulesLoadFailed = "user_rules_load_failed"
    case userRulesReloaded = "user_rules_reloaded"
    case generic
    case unknown  // 兜底：遇到 SPEC-005 v2.x 之后新增的 kind 值

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = NotifyKind(rawValue: raw) ?? .unknown
    }
}
```

`unknown` 在 UI 层降级到通用文案（"Sieve 内部通知"）+ 灰色图标，不展开详情。

### 4.3 未知 `context.template`

SPEC-005 §6.1.3 规定：未知 `template` 必须降级到 `generic_json`，把整个 context 对象作为 `payload` 渲染。GUI 端实现：

```swift
struct HipsContext: Codable {
    let template: ContextTemplate
    let payload: AnyCodable  // 用通用容器吃下任何 JSON 子树
}
```

`HipsRequestDecoder.swift` 在解析失败时统一降级到 `generic_json`，不抛错。

### 4.4 缺失 / 字段类型错误

- `request_decision` 任何**必需字段**缺失或类型错 → 整条消息 reject，回 `-32101 gui_render_failed`，daemon 端按 `default_on_timeout` 处置
- 可选字段缺失 → 走 `null` / 默认值
- `received_at_daemon` 解析失败 → 不阻断渲染，弹窗倒计时退化到从"收到消息时刻"起算

---

## 5. UI 状态机映射

### 5.1 菜单栏指示灯

| GUI IPC 状态 | daemon `paused` | 菜单栏图标 |
|---|---|---|
| disconnected | — | 灰色（断开） |
| handshaking | — | 灰色 + 旋转 |
| connected | false | 绿色（保护中） |
| connected | true | 黄色（已暂停） |
| retrying | — | 黄色 + 旋转 |

`paused` 字段同时受 `sieve.hello.paused` 和 `sieve.paused_changed` 两路更新；后者优先。

### 5.2 HIPS 弹窗排队

`request_decision` 收到后进入 `pendingQueue`：

- 同时只渲染一个 active 弹窗（`activeRequest`）
- 同 `request_id` 二次到达 → 视为 daemon 端重发（GUI 重连场景），用新 params 替换旧 entry
- `request_decision_canceled` → 从 queue 移除或关闭 active 弹窗
- daemon 断开 → queue 清空，所有弹窗关闭并显示"daemon 已断开，本次决策已由系统兜底"

### 5.3 Toast 渲染

`sieve.notify_status_bar` 走 `toastController.presentEvent`：

| `kind` | UI 表现 |
|---|---|
| `sequence_hit` | 黄色 toast，常驻直到用户点击 |
| `outbound_redacted` | 蓝色 toast，5 秒自动消失 |
| `hook_terminal` | 灰色 toast，8 秒自动消失，点击跳转 History |
| `user_rules_load_failed` | 红色 toast，常驻 + 点击打开 Settings → Detection |
| `user_rules_reloaded` | 绿色 toast，5 秒自动消失 |
| `generic` | 灰色 toast，按 daemon 给的 `auto_dismiss_seconds` 决定 |
| `unknown`（GUI 兜底） | 灰色 toast，5 秒自动消失，文案"Sieve 内部通知" |

详见 [SPEC-007](../specs/SPEC-007-toast-and-system-notifications.md)。

---

## 6. 错误码处理

GUI 端按 SPEC-005 §12 段位划分处理：

### 6.1 GUI 发出的错误（`-32100 ~ -32199`）

| Code | Swift 触发点 |
|---|---|
| `-32100` `user_canceled_via_window_close` | 用户点 HIPS 弹窗关闭按钮或按 ESC |
| `-32101` `gui_render_failed` | `HipsRequestDecoder` 抛错、SwiftUI 渲染异常 |
| `-32102` `gui_shutdown_during_decision` | App lifecycle terminate 时 inflight 请求兜底 |

### 6.2 daemon 发来的错误（`-32000 ~ -32099`）GUI 文案

| Code | 显示文案（已本地化） |
|---|---|
| `-32001` `critical_lock_violated` | "此规则受 Critical 锁保护，不能调整。" + 引导用户读 PRD §9 #3 |
| `-32002` `daemon_busy` | "daemon 正在重载，请几秒后重试。" |
| `-32003` `payload_too_large` | "粘贴内容超过 64KB 上限，请压缩后重试。" |
| `-32004` `unknown_fingerprint` | "该灰名单条目已不存在（可能被另一窗口删除）。"（同时刷新 graylist 列表） |
| 未知 daemon 错误码 | "daemon 返回未知错误（code=<n>）"，提示用户更新 GUI |

---

## 7. 多 GUI 并存

SPEC-005 允许多 GUI 同时连接 daemon（多窗口场景）。GUI 端注意：

- `request_decision` 由 daemon 路由给"最早连接的 GUI"，本 GUI 收不到 ≠ 没有待处理决策；用户可能在另一个窗口处理
- `preset_changed` / `paused_changed` / `notify_status_bar` 是 fan-out，所有 GUI 都会收到，按 `source` 字段判断是否本 GUI 自己的回声
- `list_graylist` / `health` 是只读，多 GUI 各自调用互不影响

---

## 8. 日志与诊断

GUI 自身的 IPC 行为日志写入 `~/.sieve/gui.log`（详见 SPEC-006 / SPEC-008）。脱敏要求：

- **wire 上收到的 `request_decision.context` 永远不写入 gui.log**（避免间接泄露原文）
- 只允许记录 method 名、message id、解析成功/失败、错误码
- `gui.log` rotate 策略：每天一份，保留 7 天

诊断包默认脱敏；详见 [SPEC-009](../specs/SPEC-009-diagnostic-bundle.md)（如已落地）。

---

## 9. 协议升级流程（GUI 视角）

当 SPEC-005 升版（如 v2 → v3）：

1. daemon 仓库先 merge SPEC + 代码 PR
2. GUI 仓库 `docs/external/upstream-references.md` 更新 SPEC-005 commit pin
3. 本仓库代码 PR 实施新 schema：
   - 升级 IPCClient 的 `protocol_version` 白名单（如 `["v2"]` → `["v3"]`，**通常不并存支持多版本**——避免分支爆炸）
   - 重写受影响的 Codable 结构
   - 跑 `swift test --filter IPCSchemaV3FixtureTests`（fixture 来自 daemon 仓库）
4. 本 GUI 文件的"协议版本"段落同步更新

---

## 10. 关联文档

- 上游权威 SPEC：`sieve/docs/specs/SPEC-005-ipc-protocol.md`
- 上游引用清单：[upstream-references.md](../external/upstream-references.md)
- GUI 实现规格：[SPEC-008-ipc-client.md](../specs/SPEC-008-ipc-client.md)
- HIPS 渲染规格：[SPEC-002-hips-popup-window.md](../specs/SPEC-002-hips-popup-window.md)
- Toast 规格：[SPEC-007-toast-and-system-notifications.md](../specs/SPEC-007-toast-and-system-notifications.md)
- 架构：[../design/architecture.md](../design/architecture.md)

---

## 11. 变更记录

| 版本 | 日期 | 作者 | 变更 |
|---|---|---|---|
| v1.0 | 2026-05-02（早晨） | SieveAI | 首次起草，描述协议 v1（已弃用） |
| v2.0 | 2026-05-02（午后） | SieveAI | 重写为 GUI 实现注解。所有 schema 定义迁移到上游 SPEC-005，本文件仅保留 GUI 端本地行为。协议升至 v2，落锤 D1–D8 决策。 |
| v2.1 | 2026-05-07 | SieveAI | unix-style 改造适配。新增 §12 health.listeners[] GUI 实现注解（ADR-026），加 ADR-028 协议术语中性化说明（method 名 / wire 字段保持向后兼容，GUI 代码无改动）。 |

---

## 12. `sieve.health` `listeners[]` 字段（GUI 实现注解，ADR-026）

> **权威 schema**：上游 SPEC-005 §9.5 + §9.5.4 ListenerSnapshot
> **GUI 实现**：`Sources/Models/IPCResponses.swift` `HealthResultDTO`

### 12.1 双兼容策略

`sieve.health` 响应的 `listeners: ListenerSnapshot[]` 字段自 ADR-026 起新增（v2.x 向后兼容扩展，**未 bump 协议版本号**）。GUI 端按以下规则消费：

1. **新 daemon**（已 ship ADR-026）：返回 `listeners[]`（每项 `addr / port / provider_id / protocol`）+ `listen` 字段（= `listeners[0]` 别名，向后兼容旧 client）
2. **旧 daemon**（ADR-026 落地前的 v0.7.x）：仅返回 `listen` 单值，不发 `listeners[]`
3. **GUI 解码侧**：用 `decodeIfPresent(...) ?? []` 兜底，旧 daemon → `listeners` 为空数组
4. **GUI 渲染侧**：通过 `HealthResultDTO.effectiveListeners` 统一访问 —— 优先 `listeners[]`，空时回落到 `listen` 派生的单元素数组（`provider_id / protocol` 字段填 `"(legacy)"`）

### 12.2 UI 展示约束

- Settings → Daemon Tab "Listeners" 段：列每个 listener 的 `port + provider_id + protocol`；旧 daemon 退化路径展示 `addr:port`（不假装有 provider_id）
- Onboarding step 2 doctor：基于真实 health 字段构造 checks（`listeners.isEmpty` → "daemon listener 已绑定" 项标红，引导用户检查 `sieve.toml [[upstream]]` 配置）

### 12.3 错位告警（不在 GUI 范围）

ADR-026 §决策 4 规定：listener `protocol` 与请求 path 错位时 daemon 直接 fail-closed 400，注入 `sieve_blocked` event。GUI 不主动检测错位（daemon 端硬约束），但可通过 History → 事件列表观察到 `kind=sieve_blocked` 条目。

---

## 13. ADR-028 协议术语中性化（GUI 实现影响）

ADR-028 在 SPEC-005 v2.x 落地了协议层术语清洗 + 内部模块化 + headless decision path。**对 GUI 端 wire 行为零影响**：

| 项 | 状态 |
|---|---|
| 协议版本号 | 不变（仍 v2） |
| `sieve.request_decision` / `sieve.request_decision_canceled` method 名 | 保留（**未** rename 为 `decision.pending` / `decision.canceled`，与 ADR-028 §1 表格中的"理想新名"不同；上游为最大向后兼容选择保留旧名） |
| `gui_popup` disposition 枚举值 | 保留（向后兼容硬要求） |
| GUI Codable 结构 | 无改动 |
| GUI 客户端在协议层的"特权"地位 | 取消（daemon 不再视 GUI 为特权 client；CLI / TUI 等 headless client 在协议层平等） |

**GUI 端唯一动作**：上游引用文档（本文件 + `docs/external/upstream-references.md`）同步标注 ADR-028 决策与 SPEC-005 §3.3 的 admonition 段落（"以下行为属于 GUI 实现细节，不是协议契约"）。
