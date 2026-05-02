# SPEC-007：状态栏 Toast 与系统通知

> Version: v1.0 — 2026-05-02
> Status: Stable
> Owner: doskey
> 关联 ADR：ADR-001, ADR-003
> 关联 PRD 章节：§5.7

---

## 0. 摘要

Toast 是对 AutoRedact/StatusBar 类事件的轻量视觉反馈，以右上角浮动 NSPanel 形式出现，5 秒淡出，不打断用户工作流。系统通知（`UNUserNotificationCenter`）用于 daemon 失联、HIPS 自动 deny 等需要用户知晓但 GUI 可能不在前台的场景。两者都不展示原始命中内容，仅显示脱敏摘要。

---

## 1. 范围与非目标

**范围**：
- Toast 的触发、内容渲染、合并逻辑、淡出时长
- 多条 Toast 堆叠与"超量"降级（改用菜单栏角标）
- 系统通知（`UNUserNotificationCenter`）的触发时机与内容
- 反馈入口：Toast 可点击跳历史

**非目标**：
- HIPS 弹窗（见 SPEC-002）
- 菜单栏图标状态（见 SPEC-001）
- Toast 内容的原始数据解析（数据由 `sieve.event_notify` 携带）

---

## 2. 用户路径 / 场景

### 场景 A：单次 AutoRedact
```
daemon 发 event_notify{kind:"redacted", rule_id:"OUT-01", summary:"Anthropic API key"}
  → ToastController 创建 Toast
  → 屏幕右上角从右侧滑入
  → 显示：图标 + "已脱敏 1 个 Anthropic API key" + "OUT-01 · 出站"
  → 5 秒后淡出
```

### 场景 B：5 秒内多次命中（合并）
```
5s 内 3 次 event_notify（OUT-01 × 2 + OUT-09 × 1）
  → ToastController 合并为"已脱敏 3 次"+ 展开折叠列表
  → 点"展开" → 列表显示：OUT-01 ×2 · OUT-09 ×1
```

### 场景 C：刷屏降级
```
5s 内 5 次以上或同时 ≥ 3 个 Toast 堆叠
  → 停止新 Toast，改为菜单栏 warning 角标 +1
  → 用户点菜单栏图标 → Quick Menu 显示最近命中
```

### 场景 D：系统通知（HIPS auto-deny）
```
GUI 未运行 / GUI 与 daemon 失联 → daemon 按 default_on_timeout 处置
  → GUI 重启后 or 重连后，发系统通知："Sieve 拦截：IN-CR-05，GUI 未运行，已自动拒绝"
```

---

## 3. 状态机

```
              event_notify 到达
idle ──────────────────────────► check_throttle
                                     │
                  throttle OK        │  throttle exceeded
                  ┌──────────────────┘  （≥3 堆叠 or 5s 内 >5 次）
                  ▼                        ▼
              show_toast             skip_toast + badge +1
                  │
          5s（用户可配置）
                  │
              fade_out（250ms ease-out）
                  │
               removed

（合并逻辑：same 5s window 内同 kind → 合并更新已有 toast 的计数，不新建）
```

---

## 4. UI 规格

### 4.1 Toast 外观

位置：屏幕右上角，距顶部 38pt（菜单栏下方），距右边 18pt。  
NSPanel `windowLevel = .statusBar`，`collectionBehavior = .canJoinAllSpaces`。

尺寸：宽 340pt，高自适应（最小 60pt）。  
材质：`NSVisualEffectView`（vibrancy，与系统一致）。  
圆角：12pt。

**单条 Toast 布局**：
```
┌─────────────────────────────────────────────────────┐
│  [图标 28×28]   Sieve                       now     │ ← 标题行
│                 已脱敏 1 个 Anthropic API key        │ ← 主文（13pt bold）
│                 OUT-01 · 出站 · 5 秒后消失           │ ← 副文（mono 11pt）
│                                          [查看]      │ ← 可选跳转按钮
└─────────────────────────────────────────────────────┘
```

**合并 Toast 布局**（多条同类型）：
```
┌─────────────────────────────────────────────────────┐
│  [图标]   Sieve                             now     │
│           已脱敏 3 次（合并）                        │
│           OUT-01 ×2 · OUT-09 ×1             [展开▾] │
└─────────────────────────────────────────────────────┘
```

**图标颜色与内容**：

| 事件类型 | 图标 | 背景色 |
|---------|-----|------|
| `kind="redacted"` | 盾牌 | 橙色警告底 |
| `kind="status_marked"` | ℹ | 灰色中性底 |
| `kind="hook_terminal"` | 终端 | 灰色中性底 |

### 4.2 多条堆叠

最多同时显示 3 个 Toast（垂直堆叠，间距 8pt）。  
新 Toast 从顶部滑入，旧 Toast 向下移动。  
每个 Toast 独立计时（不因新 Toast 重置计时）。  
超过 3 个堆叠时：新 Toast 不再显示，菜单栏 warning 角标 +1（5 分钟内的累计命中计数）。

**合并规则**：5 秒内同类型（同 `kind`）的 event → 合并到已有 Toast，更新计数 + 副文。不同 `kind` 分开显示。

### 4.3 交互

- Toast 整体可点击 → 跳转历史窗口，定位到对应 `audit_event_id`
- [查看] 按钮：同上（方便精确点击）
- [展开] 按钮：展开合并列表
- 鼠标悬停：暂停淡出计时（鼠标离开后恢复 5s 倒计时）
- 手势：左滑消除 Toast

**淡出动效**：250ms ease-out，`opacity` 从 1.0 降到 0.0，然后从 UI 移除。  
**reduce-motion**：取消滑入/滑出，直接淡入/淡出。

### 4.4 时长设置

用户可在设置 → General 调整"Toast 显示时长"（3~10 秒，默认 5）。  
存储：`kToastDurationSeconds`。

### 4.5 系统通知规格

使用 `UNUserNotificationCenter`。

**触发时机**：

| 场景 | 通知标题 | 通知正文 |
|------|---------|---------|
| daemon 失联 | "Sieve 与 daemon 失联" | "daemon 仍按 fail-closed 处置 Critical 请求；GUI 失联期间无法允许。" |
| daemon 重连成功 | "Sieve 已重新连接" | "daemon 恢复正常，HIPS 弹窗已就绪。" |
| HIPS 自动 deny（GUI 未运行）| "Sieve 拦截：`rule_title`" | "GUI 未运行，已自动拒绝。daemon fail-closed 兜底。" |
| HIPS 即将弹出但 GUI 不在前台 | "Sieve 需要你的确认" | "点击以查看 HIPS 弹窗。" |

**内容约束**：
- 不在通知中展示 rule_id 以外的规则细节
- 不展示 fingerprint / session_id / evidence_meta 任何字段
- 不展示原始命中内容（PRD §5.7.2）

**通知交互**：
- 点击通知 → 唤起 Sieve GUI 并聚焦相关窗口（失联 → Quick Menu；auto-deny → 历史窗口）
- `UNNotificationContent.categoryIdentifier` 区分类型

---

## 5. 数据契约

Toast 触发由 `sieve.event_notify` 驱动，详见：
- [ipc-protocol §3.3](../api/ipc-protocol.md#33-sieveevent_notify通知)

关键字段：

| 字段 | 用途 |
|------|-----|
| `kind` | 决定 Toast 图标颜色和文案前缀 |
| `rule_id` | Toast 副文显示 |
| `summary` | Toast 主文（daemon 已本地化）|
| `direction` | Toast 副文（"出站" / "入站"）|
| `audit_event_id` | 点击 Toast 跳转历史的锚点 |
| `occurred_at` | 用于合并窗口判断（5s 内的 events 合并）|

---

## 6. 错误与降级

| 条件 | 行为 |
|------|-----|
| 通知权限未授予（Step 3 跳过）| 静默失败；系统通知不显示；GUI Toast 不受影响 |
| Toast NSPanel 创建失败 | 静默降级到菜单栏角标 +1；写 GUI log |
| 点击 Toast 时历史窗口 audit.db 不可读 | 打开历史窗口但显示空状态 + 错误提示 |
| `audit_event_id` 对应行在 audit.db 中不存在（极罕见）| 打开历史窗口到最新位置，不报错 |

---

## 7. 性能与硬约束

| 指标 | 约束 | 来源 |
|------|------|------|
| Toast 渲染延迟 | < 100ms（NSPanel 复用）| PRD §8.1 |
| Toast 内容 | 不展示原始命中内容 | PRD §9 #5 |
| 堆叠上限 | ≥3 个时改用角标，避免刷屏 | PRD §5.7.1 |
| 系统通知内容 | 仅 rule_id 等元信息，不含证据细节 | PRD §5.7.2 |
| ToastController | 单例（`NSPanel` 复用）| architecture.md §8 |

---

## 8. 测试要求

- 单次 `event_notify{kind:"redacted"}` → Toast 出现，5s 后消失
- 5s 内 3 次同 kind → 合并为单条 Toast，计数更新
- 5s 内 5 次以上 → 第 4+ 次不创建新 Toast，菜单栏角标 +1
- 点击 Toast → 历史窗口打开并滚动到 `audit_event_id` 对应行
- 鼠标悬停 → 计时暂停；离开 → 恢复 5s 倒计时
- reduce-motion 开启 → 断言无 slide 动效（快照测试）
- 系统通知（mock `UNUserNotificationCenter`）：失联场景 → 通知内容断言无 evidence_meta 字段
- Toast 时长设置改 3s → 断言 Toast 3s 后消失

---

## 9. 未决事项（OQ）

| 编号 | 问题 | 当前选项 | 截止决策 |
|------|------|---------|---------|
| OQ-007-01 | "同类型"合并窗口是按 `kind` 还是按 `rule_id`？（OUT-01 × 2 + OUT-09 × 1 是合并成 1 还是 2 条？）| 当前方案：按 `kind` 合并（都是 redacted），副文展示 rule_id 列表 | Week 6 |
| OQ-007-02 | HIPS 弹窗"即将弹出但 GUI 不在前台"的触发时机（是立即发通知还是延迟 N 秒后仍未获取焦点才发）？ | 延迟 2s，若 2s 内 NSPanel 已获焦则取消通知 | Week 7 |

---

## 10. 变更记录

| 版本 | 日期 | 作者 | 变更 |
|------|------|-----|-----|
| v1.0 | 2026-05-02 | doskey | 首次起草 |
