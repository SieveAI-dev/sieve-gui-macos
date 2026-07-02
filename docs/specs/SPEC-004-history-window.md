# SPEC-004：历史记录窗口

> Version: v1.2 — 2026-07-02
> Status: Stable
> Owner: SieveAI

---

## 0. 摘要

历史窗口从 `~/.sieve/audit.db`（只读）读取所有规则命中事件，提供分页列表、多维筛选、行展开详情、默认脱敏视图和 Touch ID 解锁机制，以及 CSV/NDJSON 强制脱敏导出。数据源为本地 SQLite，不走 IPC（避免 daemon 流量翻倍）。

---

## 1. 范围与非目标

**范围**：
- `audit.db` 只读连接与增量刷新（DispatchSource file watch）
- 列表分页（每页 50 条）、时间范围筛选、多维筛选（方向/严重度/操作类型）、关键字搜索
- 行展开 Inspector panel（右侧 360pt 区域）
- 默认脱敏视图与"完整 evidence_meta"Toggle（Touch ID 保护）
- CSV / NDJSON 强制脱敏导出
- 从历史跳转到调试窗口"重放命中"

**非目标**：
- 历史记录写入（audit.db 是 append-only，GUI 不写入）
- 原始 prompt 字节查看（audit.db 不存原文）
- 图表 / 趋势分析 / 周报（排除）
- 行为序列分析（Phase 2 评估）

---

## 2. 用户路径 / 场景

### 场景 A：查看今日命中
1. 打开历史窗口（⌘L 或 Quick Menu）
2. 默认显示"今天"范围，按时间倒序，每页 50 条
3. 所有字段默认脱敏（evidence_meta 显示为 `••••••••`）
4. 点击某行 → 右侧 Inspector 展开

### 场景 B：筛选 Critical 入站事件
1. 方向筛选器选"入站"，严重度选"Critical"
2. 列表实时更新（不需要手动刷新按钮）
3. 搜索栏输入 rule_id 关键字进一步过滤

### 场景 C：查看完整 evidence_meta（Touch ID）
1. Inspector 中点"查看完整 evidence_meta（Touch ID）"
2. LAContext 弹出 Touch ID 认证
3. 认证成功 → 5 分钟解锁会话，`prefix_hash` 等字段展开显示
4. 认证失败/取消 → 回退脱敏视图，写 GUI log

### 场景 D：导出历史
1. 点顶部 [导出] 按钮
2. Save panel 选路径和格式（.csv / .ndjson）
3. 强制脱敏导出（无论当前 Toggle 状态）
4. ≥1000 条时显示进度条 + 可取消
5. 完成后 Finder reveal + GUI log 记录（含目标路径）

---

## 3. 状态机

```
               打开窗口
closed ──────────────────► loading
                               │ audit.db 加载成功
                               ▼
                           displaying
                               │
                    file watch 触发    ◄────────────────────┐
                               │                            │
                               ▼                           增量刷新
                           incremental query ──────────────►│
                               │
                    用户操作筛选器 / 搜索
                               │
                               ▼
                           filtered view
                               │
                          点击行
                               ▼
                         inspector open
                               │
                        Touch ID 认证
                         ┌─────┴─────┐
                         │           │
                       success     failure
                         │           │
                   unlocked view  masked view
```

---

## 4. UI 规格

### 4.1 窗口布局

宽度 1080pt × 高度 660pt，水平分为两栏：

```
┌─────────────────────────────────────────────────────────────────────┐
│  历史记录                          [筛选] [导出] [刷新]               │ ← titlebar
├─────────────────────────────────────────────────────────────────────┤
│  ⌕ 搜索 rule_id / direction / fingerprint  ___________________      │
│  时间：[今天 ▾] [自定义...]   方向：[全部 ▾]  严重度：[全部 ▾]  操作：[全部 ▾] │ ← 筛选栏
├──────────────────────────────────────┬──────────────────────────────┤
│  Time     Dir  Sev   Rule     Action  │                              │
│  ──────────────────────────────────  │  Inspector Panel             │
│  16:42:03  ↗  Crit  OUT-01  redact   │  （360pt 固定宽）            │
│  15:03:11  ↘  Crit  IN-CR-05 block   │  选中行的详情                │
│  ...                                 │                              │
├──────────────────────────────────────┤                              │
│  共 137 条 · 显示 1-50 · 加载至 14 天前│                              │
└──────────────────────────────────────┴──────────────────────────────┘
```

### 4.2 列表区

列宽（固定）：

| 列 | 宽度 | 内容 |
|----|------|-----|
| Time | 84pt | `HH:mm:ss`，monospace |
| Dir | 32pt | 出站 ↗（橙色）/ 入站 ↘（蓝色）|
| Sev | 80pt | `SeverityChip`（critical/high/medium/low）|
| Rule | 130pt | `rule_id`，monospace；`user:` 前缀蓝色 |
| Action | 80pt | `redact`（橙）/ `block`（红）/ `allow`（次要）/ `mark`（次要）|
| User | 80pt | `allow` / `deny` / `—`（AutoRedact 无用户决策）|
| Detail | 1fr | `•••••••• 已脱敏 · {hint}`（默认）|

Detail 列始终显示 hint（来自 `events.rule_id` + action 的语义摘要，非原文）。`hint` 字段本身已在 audit.db 中脱敏（不存原文）。

选中行：背景色 `macOS accent`，文字白色，SeverityChip 改为白色 uppercase 文字。

偶数行：淡灰背景（`rgba(0,0,0,0.015)`），提升可读性。

**分页**：每页 50 条。列表底部状态栏显示总条数、当前显示范围、已加载回溯时间。到达底部时自动加载下一页（虚拟滚动，每次最多加载 200 条到内存）。

### 4.3 筛选栏

| 控件 | 行为 |
|------|-----|
| 搜索框 | 实时 LIKE 查询 `rule_id` / `fingerprint` 前缀；去抖 200ms |
| 时间范围 Picker | 今天（默认）/ 最近 7 天 / 最近 30 天 / 自定义日期区间 |
| 方向 Picker | 全部 / 出站 / 入站 |
| 严重度 Picker | 全部 / Critical / High / Medium / Low |
| 操作 Picker | 全部 / GuiPopup / AutoRedact / StatusBar / HookTerminal |

筛选条件变更后立即触发 SQL 查询（见 [data-model.md §2.3](../design/data-model.md#23-gui-查询示例)）。

### 4.4 Inspector Panel

选中一行后，右侧 360pt 区域显示详情：

```
Event #1024                               ← 11pt uppercase 次要色
IN-CR-05                                  ← rule_id 16pt bold
签名工具调用 · signTransaction             ← hint 12pt 次要色
[Critical] [Inbound] [block]              ← chips

──────────────────────────────────
time:         2026-05-02 15:03:11.234
fingerprint:  7a3f…e9c2
session_id:   a8b1…
caller_pid:   12345（仅 audit schema v2 有值）
caller_exe:   claude

──────────────────────────────────
evidence_meta:
  {
    "len": 412,
    "prefix_hash": "••••••••",  ← 默认 mask
    "tool_name": "signTransaction"
  }
                    [眼睛图标] 已脱敏

──────────────────────────────────
🔒 此规则受 critical_lock 保护，无法加入灰名单。

[👆 查看完整 evidence_meta（Touch ID）]
[🔧 在调试窗口重放此命中]
[📋 复制 audit event id]
```

**脱敏视图（默认）**：
- `evidence_meta.prefix_hash` / `suffix_hash` 等哈希字段显示为 `••••••••`
- 整个 evidence_meta 块的详细内容折叠，只显示非敏感字段（`len` / `tool_name` 等）
- session_id 只显示前 8 字符 + `…`
- caller_exe 只显示 basename（不显示完整路径）

**"查看完整 evidence_meta"Toggle（顶部右侧）**：
- 默认关闭（`kHistoryMaskByDefault`）
- 开启需要 Touch ID（5 分钟解锁会话，复用 `AppState.unlockSession`）
- 该解锁会话**仅属于 History**：HIPS 弹窗的字段解锁已隔离为独立机制
  （`HipsFieldUnlock` 单弹窗有效，见 SPEC-002 §4.4），互不放行
- 会话到期由 `AppState.setUnlockSession` 的过期定时器主动清空（P1-1），
  不依赖 UI 读取时惰性重算；锁屏（com.apple.screenIsLocked）/ 显示器睡眠 /
  快速用户切换任一信号即清（P1-2）
- 开启后 `prefix_hash` 等字段显示完整内容
- 注：audit.db 本来就不存原始 prompt 字节

**关联灰名单**：
- critical_lock 规则显示"此规则受 critical_lock 保护，无法加入灰名单"
- 其他规则：显示关联的灰名单条目（fingerprint 匹配），或显示"—"

**行右键菜单**：复制行 / 在历史中定位（无需动作，已选中）/ 用此 fingerprint 搜灰名单。

---

## 5. 数据契约

### 5.1 数据源

只读 SQLite 连接，详见 [data-model.md §2](../design/data-model.md#2-auditdb-只读视图)。

核心查询字段（来自 `events` 表）：

| 字段 | 列表显示 | Inspector 显示 |
|------|---------|--------------|
| `id` | — | Event # |
| `created_at` | Time 列 | time 行 |
| `direction` | Dir 列 | chip |
| `severity` | Sev 列 | chip |
| `rule_id` | Rule 列 | 标题 |
| `disposition` | Action 列 | chip |
| `user_choice` | User 列 | chip |
| `fingerprint` | Detail 列（短前缀）| fingerprint 行 |
| `session_id` | — | session_id 行（短前缀）|
| `caller_pid` | — | caller_pid 行（schema v2）|
| `caller_exe` | — | caller_exe 行（basename）|
| `evidence_meta` | — | evidence_meta 块 |
| `request_id` | — | 右键菜单 / 复制 |

增量刷新策略：记录上次 `max(id)` → 下次 file watch 触发时查 `id > lastSeen`（避免全表扫）。

schema 不兼容降级：见 [data-model.md §2.4](../design/data-model.md#24-schema-不兼容降级fail-soft)。

### 5.2 导出格式

**CSV 字段**（强制脱敏）：
```
timestamp, direction, severity, rule_id, disposition, user_choice, fingerprint, caller_exe_basename
```

**NDJSON 字段**（强制脱敏）：
```json
{"timestamp":"...","direction":"inbound","severity":"critical","rule_id":"IN-CR-05","disposition":"GuiPopup","user_choice":"deny","fingerprint":"7a3f…","caller_exe":"claude"}
```

**排除字段**（不论当前 Toggle 状态）：
- `evidence_meta` 详细字段（`prefix_hash` / `suffix_hash` / 完整哈希）
- `session_id`
- `caller_pid`
- `caller_exe` 完整路径（仅保留 basename）

导出操作记录到 `~/.sieve/gui.log`（含目标路径 + 时间戳），不写 audit.db。

---

## 6. 错误与降级

| 条件 | 行为 |
|------|-----|
| `audit.db` 不存在 / 无权限 | 空状态视图："历史文件不可读，请运行 sieve doctor" + 修复引导 |
| `audit.db` schema 未知 version | 顶部 banner 警告；仍展示 v1 字段，未知字段显示 `—`（fail-soft）|
| Touch ID 不可用 | evidence_meta 展开按钮改为"密码认证"（macOS LAContext fallback）|
| Touch ID 失败 / 取消 | 回退脱敏视图；写 GUI log（不写 audit.db）|
| IPC 失联 | 历史窗口顶部 banner；列表数据可继续浏览（来自本地 SQLite）|
| 导出失败（磁盘满 / 权限）| alert 错误提示 + 磁盘空间建议 |
| "在调试窗口重放"点击时调试窗口未打开 | 自动打开调试窗口并聚焦，同时传递 `request_id` |

---

## 7. 性能与硬约束

| 指标 | 约束 |
|------|------|
| 历史窗口加载 1 万条 | < 500ms |
| 分页 LIMIT | 每次最多 50 条，加上分页，防止全表加载卡顿 |
| file watch 去抖 | 100ms |
| 默认脱敏 | 历史窗口所有字段默认 mask，Toggle 开启需 Touch ID |
| 导出 | 必须强制脱敏，不论当前 Toggle 状态 |
| 原始 prompt 字节 | 不存储，不展示；evidence_meta 只展示 meta（非原文）|
| GUI 不写 audit.db | 任何操作不触发 audit.db 写入 |

---

## 8. 测试要求

- 默认打开 → 断言 evidence_meta hash 字段为 `••••••••`（脱敏快照）
- Touch ID mock 成功 → 断言 prefix_hash 字段展开
- Touch ID mock 失败 → 断言回退脱敏视图
- 5 分钟会话过期（mock `AppState.unlockSession.expiresAt` 过去）→ 断言再次触发认证
- 时间范围筛选"今天"→ 断言 SQL `WHERE created_at >= today_00:00`
- 筛选 direction=inbound → 断言列表无出站行
- 搜索"IN-CR" → 断言列表只含匹配 rule_id 的行
- audit.db file watch 触发 → 断言增量查询（id > lastSeen，不全表扫）
- audit.db schema `user_version=999`（未知）→ 断言 banner 存在，列表不崩溃
- 导出 CSV → 断言输出不含 evidence_meta hash / session_id / caller_pid / caller_exe 完整路径
- 导出 ≥1000 条 → 断言进度条出现
- GUI 日志记录导出事件（含目标路径）

---

## 9. 变更记录

| 版本 | 日期 | 作者 | 变更 |
|------|------|-----|-----|
| v1.0 | 2026-05-02 | SieveAI | 首次起草 |
| v1.1 | 2026-07-02 | SieveAI | 标注解锁会话被 HIPS 跨窗口消费（隔离决策待定）；补记会话过期主动清空（P1-1）与三路锁屏清会话信号（P1-2） |
| v1.2 | 2026-07-02 | SieveAI | 跨窗口共享已移除：解锁会话仅属 History，HIPS 字段解锁独立（SPEC-002 §4.4） |
