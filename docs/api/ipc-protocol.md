# IPC 协议参考 — GUI ↔ daemon

> Version: v1.0 — 2026-05-02
> Status: Stable
> Owner: doskey
> 上游契约：[ADR-013](../external/upstream-references.md#adr-013ipc-protocol) · [SPEC-002](../external/upstream-references.md#spec-002hips-popup-behavior)
> GUI 实现端：[SPEC-008](../specs/SPEC-008-ipc-client.md)

---

## 0. 摘要

GUI 和 daemon 之间的所有通信走 **Unix Domain Socket + JSON-RPC 2.0**。本文件是**两个仓库共同的契约**——任何修改必须双仓库同步并递增 `protocol_version`。

- **socket 路径**：`~/.sieve/ipc.sock`
- **socket 权限**：`0600`（仅 owner）
- **协议**：JSON-RPC 2.0，**无 batch**
- **服务端可主动 notify**（daemon → GUI，无 id 字段）
- **当前协议版本**：`v1`
- **传输**：每条消息一行 JSON + `\n` 终止符（newline-delimited JSON）

---

## 1. 握手

GUI 连接 socket 后，daemon **主动发** `sieve.hello`（notification，无 id）：

```json
{
  "jsonrpc": "2.0",
  "method": "sieve.hello",
  "params": {
    "protocol_version": "v1",
    "daemon_version": "0.7.2",
    "paused": false,
    "preset": "Standard",
    "uptime_seconds": 14523,
    "audit_db_user_version": 2
  }
}
```

GUI 端处理：
1. 检查 `protocol_version`：不在 `["v1"]` 白名单 → 关闭连接，进入 disconnected 状态，UI 引导升级
2. 缓存 `daemon_version` 到 `kLastSeenDaemonVersion`
3. 同步 `paused` / `preset` 到 `AppState`
4. 标记 connected

**daemon 不主动重发 hello**，除非 GUI 重连后建立新 socket。

---

## 2. 心跳与超时

- **不**显式 ping/pong（避免协议噪音）
- daemon 在没有其他流量时，每 25s 发一条 `sieve.heartbeat` notification（仅 method）
- GUI 30s 内未收到任何消息 → 视为失联，关闭重连

---

## 3. daemon → GUI 消息

### 3.1 `sieve.request_decision`（request）

**含 id**，期望 GUI 回 `decision_response`。

#### 单 issue 形式

```jsonc
{
  "jsonrpc": "2.0",
  "method": "sieve.request_decision",
  "id": "8f3a2b91-...",
  "params": {
    "request_id": "8f3a2b91-...",          // 与 id 相同（冗余便于日志）
    "rule_id": "IN-CR-05",
    "title": "签名工具调用：signTransaction", // 已本地化（语言由 daemon 决定）
    "severity": "critical",                 // critical | high | medium | low
    "direction": "inbound",                 // inbound | outbound
    "disposition": "GuiPopup",
    "timeout_seconds": 120,
    "default_on_timeout": "Block",          // Block | Allow
    "allow_remember": false,                // ← 关键：daemon 算，GUI 不改
    "merged": false,
    "context": {
      "template": "signing_tool_use",       // 见 §3.1.1 模板表
      // template 特定字段
      "tool_name": "signTransaction",
      "chain": "Ethereum",
      "chain_id": 1,
      "typed_data": { /* EIP-712 结构 */ },
      "flags": {
        "infinite_amount": true,
        "deadline_zero": true,
        "approve_all": false
      }
    },
    "recommendation": {
      "decision": "deny",                   // deny | allow
      "confidence": "high",                 // high | medium | low
      "reason": "deadline=0 + 无限 amount 是 Permit2 钓鱼经典模式"
    },
    "received_at_daemon": "2026-05-02T15:03:11.234Z"
  }
}
```

#### 多 issue 合并形式

```jsonc
{
  "jsonrpc": "2.0",
  "method": "sieve.request_decision",
  "id": "9c1d...",
  "params": {
    "request_id": "9c1d...",
    "title": "Sieve 检测到 2 个安全问题",
    "severity": "critical",                 // 取最严重
    "direction": "inbound",
    "disposition": "GuiPopup",
    "timeout_seconds": 30,                  // 取最小
    "default_on_timeout": "Block",
    "allow_remember": false,                // 任一 issue allow_remember=false → 整体 false
    "merged": true,
    "issues": [
      {
        "issue_id": "i-1",
        "rule_id": "IN-CR-05",
        "title": "签名工具调用：signTransaction",
        "severity": "critical",
        "allow_remember": false,
        "context": { "template": "signing_tool_use", /* ... */ },
        "recommendation": { /* ... */ }
      },
      {
        "issue_id": "i-2",
        "rule_id": "IN-GEN-04",
        "title": "Markdown 图片外链",
        "severity": "high",
        "allow_remember": true,
        "context": { "template": "markdown_exfil", /* ... */ },
        "recommendation": { /* ... */ }
      }
    ]
  }
}
```

#### 3.1.1 `context.template` 字段表

| template | 含义 | 关键字段 |
|----------|-----|---------|
| `address_compare` | 钱包地址替换（IN-CR-01） | `original_address`, `substituted_address`, `chain`, `levenshtein` |
| `signing_tool_use` | 签名工具调用（IN-CR-05） | `tool_name`, `chain`, `typed_data`, `flags{infinite_amount, deadline_zero, approve_all}` |
| `markdown_exfil` | Markdown 外链外泄（IN-GEN-04） | `markdown_snippet`, `urls[]`, `reachable[]` |
| `secret_outbound` | BIP39/WIF/raw key 出站（OUT-07/09/10） | `secret_kind`, `prefix4`, `suffix4`, `length`, `hash_short` |
| `generic_json` | 通用兜底 | `payload` (任意 JSON tree) |

GUI 不识别的 template → 降级到 `generic_json`。

### 3.2 `sieve.request_decision_canceled`（notification）

```json
{
  "jsonrpc": "2.0",
  "method": "sieve.request_decision_canceled",
  "params": {
    "request_id": "8f3a2b91-...",
    "reason": "timeout"  // timeout | daemon_shutdown | superseded
  }
}
```

GUI 端处理：
- 如果该 request_id 在 pendingQueue 中 → 移除
- 如果是 activeRequest → 关闭弹窗，恢复菜单栏 normal
- 不弹任何提示（daemon 已按 default_on_timeout 处置）

### 3.3 `sieve.event_notify`（notification）

非 GuiPopup 类的事件（AutoRedact / StatusBar / 其他通知）：

```json
{
  "jsonrpc": "2.0",
  "method": "sieve.event_notify",
  "params": {
    "kind": "redacted",        // redacted | status_marked | hook_terminal
    "rule_id": "OUT-01",
    "severity": "critical",
    "direction": "outbound",
    "disposition": "AutoRedact",
    "summary": "Anthropic API key",  // 已本地化短语，用于 Toast
    "count": 1,
    "audit_event_id": 1024,    // events.id，可点 Toast 跳详情
    "occurred_at": "2026-05-02T15:03:11.234Z"
  }
}
```

GUI 渲染：见 [SPEC-007](../specs/SPEC-007-toast-and-system-notifications.md)。

### 3.4 `sieve.preset_changed`（notification）

```json
{
  "jsonrpc": "2.0",
  "method": "sieve.preset_changed",
  "params": {
    "preset": "Strict",        // Strict | Standard | Relaxed | Custom
    "changed_by": "cli",       // cli | gui | config_reload
    "occurred_at": "..."
  }
}
```

GUI 端处理：
- 如果 `changed_by == "gui"` → 已经是 GUI 自己的操作，忽略（避免重复刷新）
- 否则 → 同步 `AppState.preset`，设置面板 picker 切换

### 3.5 `sieve.heartbeat`（notification）

```json
{ "jsonrpc": "2.0", "method": "sieve.heartbeat" }
```

无 params。GUI 端只刷新"最近收到消息时间"，不做其他动作。

---

## 4. GUI → daemon 消息

### 4.1 `sieve.decision_response`（response）

**回应 `request_decision`，使用相同 id**。

#### 单 issue / 简单形式

```jsonc
{
  "jsonrpc": "2.0",
  "id": "8f3a2b91-...",
  "result": {
    "decision": "deny",                // allow | deny
    "remember": false,                 // GUI 在 allow_remember=false 时永远 false
    "context_hint": null,              // ≤ 200 字符，用户备注
    "responded_at": "2026-05-02T15:03:18.512Z",
    "ui_phase_when_clicked": "blue"    // blue | orange | red — 调试/审计用
  }
}
```

#### 多 issue 部分允许

```jsonc
{
  "jsonrpc": "2.0",
  "id": "9c1d...",
  "result": {
    "merged_decision": "partial",      // all_deny | all_allow | partial
    "per_issue": [
      { "issue_id": "i-1", "decision": "deny",  "remember": false },
      { "issue_id": "i-2", "decision": "allow", "remember": true, "context_hint": "测试中允许" }
    ],
    "responded_at": "..."
  }
}
```

#### 错误回应

```json
{
  "jsonrpc": "2.0",
  "id": "8f3a2b91-...",
  "error": {
    "code": -32000,
    "message": "user_canceled_via_window_close"
  }
}
```

错误码（GUI 侧）：

| code | 含义 | daemon 处置 |
|------|-----|------------|
| `-32000` | `user_canceled_via_window_close` | 等同 default_on_timeout |
| `-32001` | `gui_render_failed` | 等同 default_on_timeout + 系统通知告警 |
| `-32002` | `gui_shutdown_during_decision` | 等同 default_on_timeout |

### 4.2 `sieve.set_paused`（request）

```json
{
  "jsonrpc": "2.0",
  "method": "sieve.set_paused",
  "id": "<uuid>",
  "params": { "minutes": 30 }
}
```

response：

```json
{
  "jsonrpc": "2.0",
  "id": "<uuid>",
  "result": {
    "paused_until": "2026-05-02T15:33:11.234Z",
    "critical_still_blocks": true
  }
}
```

### 4.3 `sieve.set_preset` / `sieve.set_preset_overrides`

```json
{
  "jsonrpc": "2.0",
  "method": "sieve.set_preset",
  "id": "<uuid>",
  "params": { "mode": "Strict" }
}
```

```json
{
  "jsonrpc": "2.0",
  "method": "sieve.set_preset_overrides",
  "id": "<uuid>",
  "params": {
    "mode": "Custom",
    "overrides": [
      { "rule_id": "OUT-08", "timeout_seconds": 90, "default_on_timeout": "Allow" }
    ]
  }
}
```

response（成功）：

```json
{ "jsonrpc": "2.0", "id": "<uuid>", "result": { "ok": true } }
```

response（违反 critical_lock）：

```json
{
  "jsonrpc": "2.0",
  "id": "<uuid>",
  "error": {
    "code": -32010,
    "message": "critical_lock_violation",
    "data": { "rule_id": "IN-CR-05", "field": "default_on_timeout" }
  }
}
```

### 4.4 `sieve.reload_config`

```json
{ "jsonrpc": "2.0", "method": "sieve.reload_config", "id": "<uuid>" }
```

response：

```json
{
  "jsonrpc": "2.0",
  "id": "<uuid>",
  "result": {
    "ok": true,
    "rules_loaded": 47,
    "user_rules_loaded": 3,
    "warnings": []
  }
}
```

### 4.5 `sieve.evaluate`（沙箱评估）

```json
{
  "jsonrpc": "2.0",
  "method": "sieve.evaluate",
  "id": "<uuid>",
  "params": {
    "direction": "outbound",
    "content_kind": "tool_use_input",   // text | tool_use_input | sse_chunk
    "payload": "<≤ 64 KB>",
    "source_agent": "claude-code"
  }
}
```

response：

```json
{
  "jsonrpc": "2.0",
  "id": "<uuid>",
  "result": {
    "evaluated_rules": 47,
    "matches": [
      {
        "rule_id": "IN-GEN-02",
        "severity": "critical",
        "disposition": "HookTerminal",
        "matched_pattern": "curl POST",
        "matched_canonical": "...",
        "fields": ["body.text"],
        "redacted_evidence": "..."     // critical_lock 规则只返回脱敏摘要
      }
    ],
    "no_match": ["IN-CR-02", "user:MY-CURL-PIPE"]
  }
}
```

### 4.6 `sieve.list_graylist` / `sieve.remove_graylist`

```json
{ "jsonrpc": "2.0", "method": "sieve.list_graylist", "id": "<uuid>" }
```

```json
{
  "jsonrpc": "2.0",
  "id": "<uuid>",
  "result": {
    "entries": [
      {
        "fingerprint": "7a3f...e9c2",
        "rule_id": "IN-GEN-04",
        "created_at": "2026-04-29T10:11:00Z",
        "context_hint": "测试外链",
        "last_triggered_at": "2026-05-01T08:23:00Z",
        "trigger_count": 4
      }
    ]
  }
}
```

```json
{
  "jsonrpc": "2.0",
  "method": "sieve.remove_graylist",
  "id": "<uuid>",
  "params": { "fingerprint": "7a3f...e9c2" }
}
```

### 4.7 `sieve.health`

```json
{ "jsonrpc": "2.0", "method": "sieve.health", "id": "<uuid>" }
```

```json
{
  "jsonrpc": "2.0",
  "id": "<uuid>",
  "result": {
    "ok": true,
    "checks": [
      { "name": "ipc_socket", "ok": true },
      { "name": "audit_db_writable", "ok": true },
      { "name": "rules_loaded", "ok": true, "detail": "47 rules" },
      { "name": "anthropic_proxy_listening", "ok": true, "detail": "127.0.0.1:11453" }
    ],
    "metrics": {
      "goroutines": 23,                  // daemon 是 Rust，字段名沿用历史，实际是 task 数
      "p99_latency_ms": 12,
      "throughput_1h": 142
    }
  }
}
```

---

## 5. 错误码

| code | 名称 | 来源 | 含义 |
|------|-----|------|-----|
| `-32700` | parse_error | JSON-RPC 标准 | JSON 解析失败 |
| `-32600` | invalid_request | JSON-RPC 标准 | 请求格式不符 JSON-RPC |
| `-32601` | method_not_found | JSON-RPC 标准 | 方法不存在 |
| `-32602` | invalid_params | JSON-RPC 标准 | 参数不符合 schema |
| `-32603` | internal_error | JSON-RPC 标准 | 服务端内部错误 |
| `-32000` | user_canceled_via_window_close | GUI → daemon | 用户关闭弹窗 |
| `-32001` | gui_render_failed | GUI → daemon | GUI 渲染异常 |
| `-32002` | gui_shutdown_during_decision | GUI → daemon | GUI 进程退出 |
| `-32010` | critical_lock_violation | daemon → GUI | 试图修改 critical_lock 字段 |
| `-32011` | preset_unknown | daemon → GUI | 未知 preset 名称 |
| `-32012` | graylist_not_found | daemon → GUI | 删除不存在的 fingerprint |
| `-32013` | evaluate_payload_too_large | daemon → GUI | 沙箱评估 payload > 64KB |

---

## 6. 协议版本演进

当前 `v1`。任何下列变更视为不兼容，必须递增到 `v2`：

- 删除字段
- 修改字段语义（如 `decision` 增加新枚举值）
- 修改方法名
- 改变 disposition 枚举集合
- 改变握手时序

向后兼容的变更（不递增）：

- 新增可选字段（GUI 必须忽略未知字段）
- 新增方法（GUI 必须返回 `method_not_found` 而不是 crash）
- 新增 `error.code`（GUI 必须有 fallback "未知错误" 文案）

---

## 7. 协议层硬约束（GUI 实现端）

复述 [PRD §6.4](../requirements/sieve-gui-macos-prd-v1.0.md) 与 [上游 ADR-021](../external/upstream-references.md#adr-021tri-state-decision-and-graylist)：

1. **`allow_remember == false` 时，GUI 永远不能在 `decision_response` 里返回 `remember: true`**——即便 UI bug 让 checkbox 被勾上也必须在编码层 reject
2. **`recommendation` 缺失或 `confidence != "high"` 时，主按钮 = 拒绝，键盘 Return 默认 = 拒绝**
3. **未知字段必须忽略**，不能拒绝整条消息
4. **同 request_id 的多次 response**：daemon 端有去重保护，GUI 重连后重发同 id 的 decision_response 是允许的
5. **GUI 不发送任何敏感原文回 daemon**，`context_hint` 由用户输入，GUI 不预填

---

## 8. 变更记录

| 版本 | 日期 | 作者 | 变更 |
|------|------|-----|-----|
| v1.0 | 2026-05-02 | doskey | 首次起草，对应 protocol v1 |
