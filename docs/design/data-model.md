# 本地数据模型

> Version: v1.0 — 2026-05-02
> Status: Stable
> Owner: SieveAI
> 关联：[architecture.md](architecture.md) · [SPEC-004 历史窗口](../specs/SPEC-004-history-window.md) · [上游 audit.db schema](../external/upstream-references.md#audit-db-schema)

---

## 0. 摘要

GUI 自身**不持有规则、不写检测结果**。本地数据只有四类：

1. **UserDefaults**（用户设置 + 启动状态）
2. **`~/.sieve/audit.db` 只读视图**（历史窗口的数据源）
3. **内存域模型**（HIPS 请求 / 解锁会话 / 失联缓存）
4. **`~/.sieve/gui.log`**（自身日志）

灰名单（graylist）**不**走本地——通过 IPC 向 daemon 拉取/删除。

---

## 1. UserDefaults schema

域名：`com.sieve.gui`（应用 BundleID）。
schema 版本字段：`prefsSchemaVersion: Int`（当前 `1`）。

| Key | 类型 | 默认 | 说明 |
|-----|-----|------|-----|
| `prefsSchemaVersion` | Int | `1` | schema 版本，不兼容时备份后重建 |
| `kOnboardingCompletedAt` | Date? | `nil` | Onboarding 完成时间（决定是否再次进入引导） |
| `kOnboardingSkippedSteps` | [Int] | `[]` | 用户跳过的步骤号 |
| `kAppearance` | String | `"system"` | `system` / `light` / `dark` |
| `kLanguage` | String | `"system"` | `system` / `zh-Hans` / `en` |
| `kHipsSoundEnabled` | Bool | `true` | HIPS 弹窗提示音 |
| `kHipsSoundName` | String | `"Funk"` | macOS 系统音名 |
| `kReduceMotionOverride` | String | `"system"` | `system` / `on` / `off` |
| `kToastDurationSeconds` | Int | `5` | 3..10 |
| `kHistoryMaskByDefault` | Bool | `true` | 历史窗口默认脱敏 |
| `kAutoCheckUpdates` | Bool | `true` | Sparkle 自动检查更新 |
| `kLoginItemEnabled` | Bool | `true` | SMAppService 登录项 |
| `kLastSeenDaemonVersion` | String? | `nil` | 上次握手到的 daemon 版本（升级提示用）|
| `kLastIPCErrorTimestamp` | Date? | `nil` | 调试 Tab 显示 |
| `kPanelLastFrame_<windowId>` | Data? | `nil` | NSWindow.saveFrameUsingName 自动管理 |

**写入策略**：
- 单写：`UserDefaults.standard.set(...)`
- 批量更新：用 `setVolatileDomain` 不合适——直接逐键写
- 未知键：忽略（fail-soft）

**升级**：
- 启动时检查 `prefsSchemaVersion`
- 不匹配 → 备份到 `~/Library/Preferences/com.sieve.gui.bak.<时间>.plist` → 清空 → 重建默认

---

## 2. audit.db 只读视图

### 2.1 访问方式

- 库：`SQLite.swift`
- 模式：read-only（`Connection(filename, readonly: true)`）
- 路径：`NSHomeDirectory() + "/.sieve/audit.db"`
- 文件监视：`DispatchSource.makeFileSystemObjectSource(eventMask: [.write, .extend])`，去抖 100ms 后触发增量查询

### 2.2 GUI 关心的表与字段

> 完整 schema 在上游 daemon 仓库 `docs/design/data-model.md` §6。本节只列 GUI 实际查询的字段。

#### `events` 表（GUI 主要数据源）

| 字段 | 类型 | GUI 用途 |
|------|-----|---------|
| `id` | INTEGER PRIMARY KEY | 历史列表行的唯一键 |
| `created_at` | TIMESTAMP | 时间列 + 排序键 |
| `direction` | TEXT (`outbound` / `inbound`) | 方向列 + 筛选 |
| `severity` | TEXT (`critical` / `high` / `medium` / `low`) | 严重度列 + 筛选 |
| `rule_id` | TEXT | 规则列 + 筛选 + 详情 |
| `disposition` | TEXT (`AutoRedact` / `StatusBar` / `GuiPopup` / `HookTerminal`) | 操作列（映射到图标） |
| `user_choice` | TEXT? (`allow` / `deny` / `null`) | "用户决策"列；GuiPopup 才有值 |
| `fingerprint` | TEXT | 详情面板 + 关联灰名单查询 |
| `session_id` | TEXT? | 详情面板 |
| `caller_pid` | INTEGER? | 详情面板（v2 schema） |
| `caller_exe` | TEXT? | 详情面板，basename 显示 |
| `evidence_meta` | TEXT (JSON) | 详情面板"完整 evidence_meta" toggle 后展示 |
| `request_id` | TEXT? | 详情面板，关联 daemon log |

#### 其他表

- `decisions`：用户每次 HIPS 决策（GUI 不直接查；通过 `events.user_choice` 已够用）
- `graylist`：daemon 维护；GUI 走 IPC 查
- `meta`：`PRAGMA user_version`（GUI 启动检查）

### 2.3 GUI 查询示例

历史列表分页（默认今天，按时间倒序，每页 50）：

```sql
SELECT id, created_at, direction, severity, rule_id, disposition, user_choice, caller_exe
FROM events
WHERE created_at >= ?  -- today 00:00 local
ORDER BY created_at DESC
LIMIT 50 OFFSET ?;
```

行详情：

```sql
SELECT * FROM events WHERE id = ?;
```

筛选 + 搜索：

```sql
SELECT ...
FROM events
WHERE created_at BETWEEN ? AND ?
  AND (? IS NULL OR direction = ?)
  AND (? IS NULL OR severity = ?)
  AND (? IS NULL OR disposition = ?)
  AND (? IS NULL OR rule_id LIKE ? OR fingerprint LIKE ?)
ORDER BY created_at DESC
LIMIT 50 OFFSET ?;
```

**约束**：
- 所有查询都加 `LIMIT`（防止误开历史窗口加载全表）
- 增量刷新：上次 max(id) → 查 id > lastSeen
- 不缓存（直接查 SQLite，相信 PRAGMA cache_size）

### 2.4 schema 不兼容降级（fail-soft）

启动时：

```swift
let userVersion = try db.scalar("PRAGMA user_version") as! Int64
switch userVersion {
case 1: // 已知 v1
    // 全功能
case 2: // 已知 v2（含 caller_pid / caller_exe）
    // 全功能 + 显示 caller 字段
default:
    // 未知版本
    AppState.shared.showAuditSchemaWarningBanner = true
    // 仍按 v1 字段查询；遇到 SELECT 失败的字段降级为空
}
```

**禁止**：因为 schema 不识别就阻断历史窗口启动。

---

## 3. 内存域模型

> 仅生命周期 = GUI 进程在线。**不**持久化到磁盘。

### 3.1 HipsRequest

```swift
struct HipsRequest: Identifiable {
    let id: String                  // request_id (UUID)
    let receivedAt: Date
    let title: String               // 已本地化
    let severity: Severity
    let direction: Direction
    let timeoutSeconds: Int
    let defaultOnTimeout: DefaultOnTimeout  // .block | .allow
    let allowRemember: Bool         // ← 信任 daemon，GUI 不改
    let recommendation: Recommendation?
    let issues: [Issue]             // 单 issue 时长度 1
    let merged: Bool                // 多 issue 合并标记
    let rawJSON: Data               // 复制原始 JSON 用，关闭即丢

    // 渲染期状态
    var remainingSeconds: Int
    var phase: CountdownPhase       // .blue | .orange | .red

    // 决策结果
    var decision: Decision?         // .deny | .allow | .partial(...)
    var rememberChecked: Bool
    var contextHint: String?        // ≤ 200 字符
}
```

**生命周期**：
1. `IPCClient` 收 `request_decision` → 构造 → 入 `pendingQueue`
2. `HipsPanelManager` 出队 → 显示
3. 用户答复 → `IPCClient` 发 `decision_response` → 实例销毁
4. 关闭弹窗时 `rawJSON` 必须主动清零（`Data` 用完置空，避免内存残留）

### 3.2 HitSummary（最近命中）

```swift
struct HitSummary: Identifiable {
    let id: Int                     // events.id
    let timestamp: Date
    let direction: Direction
    let severity: Severity
    let ruleId: String
    let disposition: Disposition
    let userChoice: UserChoice?     // GuiPopup 才有
}
```

来源：
- IPC `event_notify`（实时）→ 直接构造
- audit.db file watch 触发 → 增量查询构造

`AppState.recentHits` 维护**最近 3 条**（FIFO 截断）。

### 3.3 TouchIDSession

```swift
final class TouchIDSession {
    let unlockedAt: Date
    let expiresAt: Date  // unlockedAt + 5min

    var isValid: Bool {
        Date() < expiresAt
    }
}
```

`AppState.unlockSession` 持有当前唯一会话；过期或显式 lock 后 set nil。

### 3.4 IPC inflight 队列

```swift
struct InflightRequest {
    let id: String
    let method: String
    let sentAt: Date
    let continuation: CheckedContinuation<JSONRPCResponse, Error>
}
```

`IPCClient` 内部维护 `[String: InflightRequest]`，重连时同 id 重发。

详见 [SPEC-008](../specs/SPEC-008-ipc-client.md) §4。

---

## 4. `~/.sieve/gui.log`

唯一 GUI 自己写的文件。

- 路径：`~/.sieve/gui.log`
- 权限：0600
- 写入：append（O_APPEND）
- Rotation：5MB × 5 文件
- 格式：每行 JSON

```json
{"ts":"2026-05-02T15:03:11.234Z","level":"info","scope":"ipc","msg":"reconnected","attempt":3}
```

字段约定：

| 字段 | 类型 | 备注 |
|------|------|-----|
| `ts` | ISO 8601 | UTC |
| `level` | `debug` / `info` / `warn` / `error` | |
| `scope` | `ipc` / `hips` / `menubar` / `settings` / `history` / `debug` / `onboarding` / `toast` / `touchid` / `update` / `app` | |
| `msg` | string | 简短英文 |
| `meta` | object? | 可选附加字段（无敏感数据） |

**禁止**：
- 写入原始命中字节
- 写入用户输入的 prompt
- 写入完整钱包地址、私钥、助记词
- 写入完整 caller_exe 路径（只写 basename）

---

## 5. 灰名单管理

GUI **不直接读** `~/.sieve/decisions/` 文件。
通过 IPC：

- `sieve.list_graylist` → 返回 `[GraylistEntry]`
- `sieve.remove_graylist{fingerprint}` → 删除单条

```swift
struct GraylistEntry: Identifiable {
    let id: String              // fingerprint
    let ruleId: String
    let createdAt: Date
    let contextHint: String?
    let lastTriggeredAt: Date?  // daemon 维护
    let triggerCount: Int       // daemon 维护
}
```

设置面板 → Privacy → 灰名单管理 sheet 显示。

---

## 6. 数据生命周期表

| 数据 | 写入者 | GUI 访问 | 持久化 | 进程退出后 |
|-----|-------|---------|-------|----------|
| UserDefaults | GUI | 读写 | ✓ | 保留 |
| audit.db | daemon | 只读 | ✓ | 保留（daemon 管） |
| graylist 文件 | daemon | 只通过 IPC | ✓（daemon 端） | 保留 |
| HipsRequest | GUI | 读写 | ✗ | 丢弃 |
| HitSummary | GUI | 读写 | ✗ | 丢弃 |
| TouchIDSession | GUI | 读写 | ✗ | 丢弃 |
| `~/.sieve/gui.log` | GUI | append | ✓ | 保留 + rotate |
| inflight 队列 | GUI | 读写 | ✗ | 丢弃（重连后由 daemon 端去重保护）|

---

## 7. 变更记录

| 版本 | 日期 | 作者 | 变更 |
|------|------|-----|-----|
| v1.0 | 2026-05-02 | SieveAI | 首次起草 |
