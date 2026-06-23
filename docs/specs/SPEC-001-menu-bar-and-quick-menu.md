# SPEC-001：菜单栏与 Quick Menu

> Version: v1.0 — 2026-05-02
> Status: Stable
> Owner: SieveAI
> 关联 PRD 章节：§5.1

---

## 0. 摘要

菜单栏模块是 Sieve GUI 的主入口。通过 `NSStatusItem` 常驻于 macOS 菜单栏，以五种图标状态实时反映 daemon 运行状况。点击图标弹出 Quick Menu popover，提供状态摘要、最近命中、暂停/恢复、以及各功能窗口的入口。

状态以 `sieve.hello` 实际握手为准，禁止"假装健康"（PRD §9 #6）。

---

## 1. 范围与非目标

**范围**：
- `NSStatusItem` 图标渲染与五种状态切换
- Quick Menu popover（宽 320pt）
- 暂停/恢复（IPC `sieve.set_paused`）
- IPC 失联时的 disconnected 降级 UI
- 菜单栏到其他窗口的导航入口

**非目标**：
- HIPS 弹窗的触发与渲染（见 SPEC-002）
- 各功能窗口的内部实现（见各自 SPEC）
- 状态图标的精确色值/间距（由设计稿决定，本 SPEC 给约束）

---

## 2. 用户路径 / 场景

### 场景 A：常规查看状态
1. 用户看到菜单栏图标为 normal 蓝色 ◐ → 知道 daemon 健康
2. 可不点击，图标即信息

### 场景 B：查看最近命中
1. 用户点击菜单栏图标 → Quick Menu 弹出
2. 查看"最近命中"3 条（已脱敏摘要）
3. 点击某条 → 历史窗口定位到该行

### 场景 C：暂停保护
1. 用户点击"暂停 30 分钟"
2. GUI 发 `sieve.set_paused{minutes:30}`
3. 菜单栏图标切换为 paused 灰色 ◌
4. Quick Menu 显示剩余时间，标注"Critical 拦截仍然生效"
5. 30 分钟到 → 自动恢复 normal

### 场景 D：失联处理
1. 30 秒内 IPC 三次失败 → disconnected 状态
2. 菜单栏图标变红 ⚠
3. 点击图标 → 显示失联 popover（非普通 Quick Menu）
4. 提供"运行 sieve doctor"和"重试连接"按钮

---

## 3. 状态机

```
                     sieve.hello 握手成功
  startup ──────────────────────────────────► normal
                                               │  │
                 有 GuiPopup hold              │  │ 5min 内 AutoRedact/StatusBar 命中
                 ┌─────────────────────────────┘  │
                 ▼                                 ▼
               hold ◄──────────────────────── warning
                 │                                 │
                 │ 弹窗全部答复/超时                │ 5min 命中清零
                 └─────────────────────────────────┘
                          │  ▲
       set_paused 成功     │  │ paused_until 到期 or set_paused{minutes:0}
                          ▼  │
                        paused
                          │
                IPC 失联（30s 3次失败 / 30s 无心跳）
                          ▼
                    disconnected
                          │
                重连成功 + sieve.hello
                          ▼
                        normal（同步 paused/preset）
```

状态优先级（高者覆盖低者）：`disconnected > hold > paused > warning > normal`

---

## 4. UI 规格

### 4.1 图标五种状态

| 状态 | 图标 | 颜色 | 附加元素 | 触发条件 |
|------|-----|------|---------|---------|
| `normal` | 筛子轮廓 ◐ | 白色（跟随菜单栏） | — | daemon 健康，无 hold 中请求 |
| `warning` | 筛子 ◑ + 角标 | 黄色 `#FFCC00` | 右上角数字角标（命中计数）| 5 分钟内有 AutoRedact/StatusBar 命中 |
| `hold` | 筛子 ● + 倒计时 | 红色 `#FF453A` | 右侧 monospaced 数字（剩余秒数）| 当前有 GuiPopup 类请求 hold 中 |
| `paused` | 筛子轮廓 ◌ | 白色 40% 透明 | — | 用户暂停 |
| `disconnected` | 筛子 + 叹号角标 | 红色 `#FF453A` | 右上角 ⚠ 图标 | IPC 失联 |

图标实现：SF Symbols `circle.lefthalf.filled` + 自绘筛子层；适配 macOS 深色/浅色菜单栏模板图像。

**约束**（PRD §5.1.1）：
- 角标计数最大显示 99，超过显示 `99+`
- hold 状态倒计时数字每秒刷新，与 HIPS 弹窗同步
- 所有状态切换 200ms ease-in-out 动效
- 减少动效开启时：取消过渡，直接切换

### 4.2 Quick Menu 布局

宽度固定 320pt，高度自适应。vibrancy 材质（`NSVisualEffectView`）。

```
┌──────────────────────────────────────────┐
│  [sieve图标]  Sieve · Standard preset    │ ← 标题行（fontWeight:600）
│  ● 健康  daemon 11453 · 2h 13m           │ ← 状态行（绿点 or 灰点）
│  今日命中：3 出站 · 1 入站                │ ← 统计行（点击→历史窗口）
├──────────────────────────────────────────┤  ← 分割线
│  最近命中                                 │ ← section header
│  16:42  OUT-01  Anthropic API key 已脱敏  │ ← 命中行（monospace 时间+rule_id）
│  15:03  IN-CR-05 签名 tool_use 已拒绝    │
│  12:11  OUT-09  BIP39 已脱敏             │
│  [⏸ 暂停 30 分钟]   [全部历史]           │ ← 操作行
│  ⓘ 暂停期间 Critical 拦截仍然生效        │ ← 说明文字（11pt 次要色）
├──────────────────────────────────────────┤
│  ⚙ 设置...                      ⌘,      │
│  📜 历史...                      ⌘L      │
│  🔧 调试...                      ⌥⌘D    │
├──────────────────────────────────────────┤
│  ❓ 帮助 / 反馈                          │
│  退出 Sieve GUI                  ⌘Q      │
└──────────────────────────────────────────┘
```

**命中行约束**：
- 每条不超过 1 行，溢出 ellipsis
- 内容：时间（monospace 5字符）+ rule_id（monospace 10字符）+ 脱敏摘要
- 绝不显示原始 prompt；所有 hint 字段来自 `HitSummary.ruleId + action`（PRD §5.1.2）
- deny 类 action 的 rule_id 显示为红色

**暂停行为**：
- 点"暂停 30 分钟" → IPC `sieve.set_paused{minutes:30}`，等待 response
- response 成功 → 状态切 paused，菜单行变"恢复（剩 27:42）"
- 暂停期间，说明行始终可见："暂停期间 Critical 拦截仍然生效"（PRD §5.1.3 硬约束）
- 不提供 > 30 分钟 / 无限期暂停（PRD §5.1.3）

**退出行为**：
- "退出 Sieve GUI" 弹 alert："daemon 仍在运行，重新打开 Sieve GUI 即可恢复 HIPS 弹窗。"（PRD §5.1.2）
- 确认后退出 GUI 进程；daemon 继续运行

### 4.3 失联 Popover（替换 Quick Menu）

当状态为 `disconnected` 时，点击图标显示失联 popover 而非普通 Quick Menu：

```
┌──────────────────────────────────────────┐
│  ⚠ [红色]  与 daemon 失联                │
│                                          │
│  30 秒内 IPC 三次失败。daemon 仍按        │
│  fail-closed 处置 Critical 请求；         │
│  GUI 失联期间无法允许。                   │
│                                          │
│  [运行 sieve doctor]  [重试连接]         │
└──────────────────────────────────────────┘
```

失联 banner 同时在所有已打开的功能窗口顶部显示（见各 SPEC §6）。

### 4.4 键盘快捷键

| 快捷键 | 行为 |
|--------|-----|
| ⌘, | 打开/聚焦设置窗口 |
| ⌘L | 打开/聚焦历史窗口 |
| ⌥⌘D | 打开/聚焦调试窗口 |
| ⌘Q | 退出 Sieve GUI |

### 4.5 可访问性

- `NSStatusItem` 设置 `accessibilityTitle`："Sieve — [状态名]"
- Quick Menu popover 内所有行支持键盘焦点环
- 命中列表行 `accessibilityLabel`：包含时间 + rule_id + action

---

## 5. 数据契约

### 5.1 状态数据来源

| 字段 | 来源 | 刷新时机 |
|------|------|---------|
| daemon 状态（connected/paused/preset）| IPC `sieve.hello` | 每次重连 |
| paused_until | IPC `sieve.set_paused` response | 操作后 |
| recentHits（最近 3 条）| `AppState.recentHits` | IPC `event_notify` + audit.db file watch |
| 今日命中统计 | audit.db 增量查询 | file watch 触发 |
| hold 倒计时数字 | `HipsPanelManager.activeRequest.remainingSeconds` | 每秒 |

IPC 消息格式详见 [ipc-protocol §1](../api/ipc-protocol.md#1-握手) 和 [ipc-protocol §4.2](../api/ipc-protocol.md#42-sieveset_paused请求)。

### 5.2 本地状态

- `AppState.daemonStatus`：`connected | paused | hold | warning | disconnected`
- `AppState.recentHits`：`[HitSummary]`，最多 3 条，FIFO
- `AppState.pausedUntil`：`Date?`

---

## 6. 错误与降级

| 条件 | 行为 |
|------|-----|
| IPC 连接失败（ENOENT）| 进入 disconnected；如 Onboarding 未完成则弹 Onboarding |
| `sieve.hello.protocol_version` 不识别 | 进入 disconnected；Quick Menu 显示"协议版本不匹配，请升级" |
| `sieve.set_paused` 超时 / 报错 | 状态回滚，Quick Menu 显示 toast "暂停失败，请重试" |
| 暂停期间 IPC 失联重连 | 重连后从 `sieve.hello.paused` 同步状态，避免 GUI 丢失 paused 状态 |
| audit.db 不可读 | 今日命中统计显示"—"，最近命中列表空；不阻断菜单栏运行 |

---

## 7. 性能与硬约束

| 指标 | 约束 | 来源 |
|------|------|------|
| Quick Menu 弹出延迟 | < 100ms（popover 复用，不每次重建） | PRD §2.2 |
| 图标状态切换 | 必须以 `sieve.hello` 握手为准，不假装健康 | PRD §9 #6 |
| hold 倒计时数字 | 与 HIPS 弹窗同步，精度 ±1s | PRD §5.1.1 |
| 暂停期间 Critical 拦截 | 菜单栏必须标注"Critical 拦截仍然生效" | PRD §5.1.3 |
| 最近命中摘要 | 绝不显示原始 prompt 内容 | PRD §5.1.2 / PRD §9 #5 |
| 退出不影响 daemon | GUI 进程退出只影响 GUI，daemon 继续 | PRD §8.2 |

---

## 8. 测试要求

### 快照测试
- 五种图标状态的渲染快照（深色/浅色各一组）
- Quick Menu 在 normal / paused / warning / hold 状态下的快照
- 失联 popover 快照

### 行为测试
- `sieve.hello{paused:true}` → 图标切 paused
- `sieve.request_decision` 入队 → 图标切 hold + 数字出现
- 30s 无心跳 → 进入 disconnected
- `sieve.set_paused` 成功 → 图标切 paused，文案含"Critical 拦截仍然生效"
- `sieve.set_paused` 报错 → 状态不变，显示错误提示
- recentHits 超过 3 条 → 只显示最新 3 条
- hold 倒计时数字每秒递减并与 `HipsPanelManager.activeRequest.remainingSeconds` 同步
- 点击命中行 → 历史窗口打开并滚动到对应行
- 退出按钮 → alert 弹出，确认后进程退出

---

## 9. 未决事项（OQ）

| 编号 | 问题 | 当前选项 | 截止决策 |
|------|------|---------|---------|
| OQ-001-01 | warning 状态的 5min 计时是基于 event 时间戳还是 GUI 收到 event_notify 的时间？ | event.occurred_at（daemon 端），避免 GUI 进程暂停导致误算 | Week 6 |
| OQ-001-02 | 多个 GuiPopup 排队时，hold 状态的倒计时数字显示哪个（第一个 or 最小剩余）？ | 显示 activeRequest（当前弹窗）的剩余秒，不显示队列中其他 | Week 6 |

---

## 10. 变更记录

| 版本 | 日期 | 作者 | 变更 |
|------|------|-----|-----|
| v1.0 | 2026-05-02 | SieveAI | 首次起草 |
