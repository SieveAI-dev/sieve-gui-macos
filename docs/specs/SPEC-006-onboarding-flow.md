# SPEC-006：安装引导流程

> Version: v1.0 — 2026-05-02
> Status: Stable
> Owner: doskey
> 关联 ADR：ADR-001, ADR-003
> 关联 PRD 章节：§5.6
> 上游依赖：[上游 SPEC-003 sieve-setup-tool](../external/upstream-references.md#spec-003sieve-setup-tool) · [上游 ADR-015](../external/upstream-references.md#adr-015sieve-setup-tool)

---

## 0. 摘要

Onboarding 是首次启动时（或修复模式下）的 6 步模态引导流程，覆盖 daemon 健康检查、通知权限申请、登录项注册、检测 preset 选择，以及演示 demo。引导期间菜单栏显示 `setup` 状态；完成后写 `kOnboardingCompletedAt`，切入正常菜单栏模式。

---

## 1. 范围与非目标

**范围**：
- 6 步引导的内容与交互
- 触发条件（首次启动 / 协议不匹配 / sieve doctor 失败 / 用户主动重放）
- daemon 健康检查（`sieve doctor` 5 项）
- 系统权限申请（通知 + LoginItem）
- daemon 不存在时的降级

**非目标**：
- `sieve setup` / `sieve doctor` 的内部实现（上游 daemon 仓库 SPEC-003 负责）
- 权限申请后的持续监控（由各功能模块自行处理）

---

## 2. 用户路径 / 场景

### 场景 A：首次安装（正常路径）
```
首次启动 → UserDefaults kOnboardingCompletedAt 不存在
  → 弹 Onboarding 模态窗口
  → Step 1（欢迎）→ Step 2（daemon 检查，全部 ✓）→ Step 3（通知权限）
  → Step 4（登录项）→ Step 5（选 preset）→ Step 6（完成 + demo）
  → 写 kOnboardingCompletedAt = now → 退出模态 → 菜单栏 normal
```

### 场景 B：daemon 检查失败（修复路径）
```
Step 2：daemon 监听检查 ✗（端口 11453 不可达）
  → 显示修复按钮：[运行 sieve setup（推荐）] [手动修复 ↗]
  → 用户点 [运行 sieve setup]
  → spawn 终端运行 `sieve setup`，窗口内显示进度
  → setup 完成 → 重新运行 `sieve doctor` 5 项检查
  → 全部 ✓ → 自动进入 Step 3
```

### 场景 C：daemon 未安装
```
Step 2：`which sieve` 找不到 + `~/.sieve/ipc.sock` 不存在
  → 显示"Sieve daemon 未安装"提示
  → 按钮：[打开下载页]（外链）
  → 不能继续引导（[继续] 按钮禁用）
```

### 场景 D：用户主动重放
```
设置 → About → [重新运行引导]
  → 弹 Onboarding（非首次，不重置 kOnboardingCompletedAt）
  → 完成后更新 kOnboardingCompletedAt
```

---

## 3. 状态机

```
              首次启动 or 触发条件命中
app_start ────────────────────────────► onboarding_start
                                              │
                                          Step 1（欢迎）
                                              │ [继续]
                                          Step 2（daemon 检查）
                                           ┌──┴────────────────────┐
                                     全 ✓  │                       │  存在 ✗
                                           │                       ▼
                                           │                fixing（运行 setup）
                                           │                       │
                                           │◄──────────── 修复后重新检查
                                           ▼
                                       Step 3（通知权限）
                                       （[请求权限] / [稍后]）
                                           │
                                       Step 4（登录项）
                                       （[开启] / [稍后]）
                                           │
                                       Step 5（选 preset）
                                           │
                                       Step 6（完成）
                                       （[运行 demo] / [完成]）
                                           │
                                   写 kOnboardingCompletedAt
                                           │
                                       normal（菜单栏模式）
```

"跳过引导"按钮（右上角，⌘W 不等于跳过）：点击弹确认 alert:"未完成引导，下次启动会再次出现"，确认后写 `kOnboardingCompletedAt = now` + 记录 `kOnboardingSkippedSteps`。

---

## 4. UI 规格

### 4.1 窗口形态

- 尺寸：720×520pt
- 模态全屏（除全屏游戏外覆盖所有窗口）
- 关闭按钮：存在但点击弹确认 alert
- 最小化/最大化：禁用
- 不可调整大小（Phase 1 内容固定）

### 4.2 布局

```
┌──────────────────────────────────────────────────────────┐
│  [●]  [◉]  [◉]    Sieve · Setup                         │ ← titlebar
├────────────────────┬─────────────────────────────────────┤
│  [侧边栏 200pt]    │  [主内容区]                          │
│                    │                                      │
│  ◉ 1. 欢迎         │  第 2/6 步                           │
│  ◉ 2. daemon 检查  │  检查守护进程                        │
│  ● 3. 通知权限     │  Sieve 在 127.0.0.1:11453 上运行    │
│  ○ 4. 登录项       │  daemon。以下是 sieve doctor 结果：  │
│  ○ 5. 选择模式     │                                      │
│  ○ 6. 完成         │  [检查项列表]                        │
│                    │                                      │
│                    │  ──────────────────────────────────  │
│                    │              [← 上一步] [跳过] [继续→]│
└────────────────────┴─────────────────────────────────────┘
```

侧边栏步骤状态图标：
- 已完成（< 当前步）：绿色 ✓
- 当前步：蓝色实心圆
- 未完成（> 当前步）：灰色空心圆

### 4.3 Step 1：欢迎

主标题：`一行价值主张文案`  
副标题：`Sieve 守护你与 AI 的每次关键对话`

三条 Bullet（图标 + 标题 + 一句描述）：
1. [盾牌图标] 本地守门人，不联网 — 所有检测在你的 Mac 完成；GUI 和 daemon 默认无外网连接。
2. [⚠ 图标] 在不可逆动作前强制确认 — DeFi 签名、API key 出站、钓鱼地址，都会被拦下来让你看清。
3. [🔒 图标] Critical 锁不可绕过 — 签名工具调用与钱包地址替换没有"记住"选项。这是产品级承诺。

按钮：[继续] [跳过引导（不推荐）]

### 4.4 Step 2：daemon 健康检查

调用 `sieve doctor` 5 项检查（对应上游 SPEC-003 §4.1）：

```
[✓] ANTHROPIC_BASE_URL 已配置        http://127.0.0.1:11453
[✓] PreToolUse hook 已注册
[✗] daemon 在监听                    未检测到端口 11453
[…] launchd 服务运行中
[…] Canary 检测通过
```

图标含义：`✓`=通过（绿），`✗`=失败（红），`…`=等待中（灰）。

**任何项 ✗ 时**：
- [运行 sieve setup（推荐）]（主按钮，spawn 终端运行 `sieve setup`）
- [手动修复 ↗]（外链打开 daemon 安装文档）

**daemon 未安装时**（`which sieve` 失败 + socket 不存在）：
- 特殊提示框："Sieve daemon 未安装。请确保你已安装完整的 Sieve（.dmg）。"
- [打开下载页]（外链）
- [继续] 按钮禁用

**全部 ✓ 时**：自动进入 Step 3（延迟 800ms，给用户时间看结果）。否则等用户手动修复。

`~/.sieve/` 目录权限校验（0700 / 0600）：检查失败时在步骤列表底部额外显示警告 + 一键修复（`chmod` 命令说明）。

### 4.5 Step 3：通知权限

说明文字：
> HIPS 弹窗需要"通知"权限以在 daemon 失联时通过系统通知告诉你 Sieve 不可用。如果不授权，失联期间你可能错过 fail-closed 提醒。

按钮：[请求权限]（`UNUserNotificationCenter.requestAuthorization`）[稍后再说]

已授权状态：显示 ✓ 绿色确认，[继续] 按钮高亮。

[稍后再说] 后的 hint：`⚠ 失联场景下你可能错过 fail-closed 提醒`

### 4.6 Step 4：登录项

说明文字：
> 建议把 Sieve GUI 加入登录项，开机自动运行。否则 daemon 拦了请求但 GUI 没启动，弹窗会延迟。

按钮：[开启登录项]（`SMAppService.mainApp.register()`）[稍后再说]

已注册状态：显示 ✓ + "已加入登录项"。

### 4.7 Step 5：选择检测模式

布局：左侧 3 个 Preset 卡片（Strict / Standard / Relaxed），右侧说明区。Standard 默认选中（推荐）。

Preset 说明（同设置 Detection Tab，PRD §5.3.2）。

按钮：[继续]（保存选择，IPC `sieve.set_preset{mode:...}`）。

### 4.8 Step 6：完成

主标题：`Sieve 已就绪`  
副标题：`Sieve 现在在菜单栏。下次模型回复包含可疑动作时，GUI 会弹窗。`

可选：[运行 demo]（向 daemon 发内置 canary，触发演示弹窗）。  
必选：[完成]（写 `kOnboardingCompletedAt = now`，关闭 Onboarding，菜单栏切 normal）。

---

## 5. 系统权限矩阵

| 权限 | 申请步骤 | 申请 API | 必须性 |
|------|---------|---------|-------|
| Notification | Step 3 | `UNUserNotificationCenter.requestAuthorization` | 强烈推荐（失联告警）|
| Login Item | Step 4 + 设置 General | `SMAppService.mainApp.register()` | 可选 |
| Touch ID / LocalAuthentication | 历史敏感字段解锁（无预申请）| `LAContext.evaluatePolicy` 按需 | 按需 |
| Local Network / Camera / Mic | 不申请 | — | 不需要 |
| Accessibility | 不申请 | — | 不需要 |
| Apple Events | 不申请 | — | 不需要 |

**注**：不主动申请任何多余权限（PRD §9 #8）。

---

## 6. 数据契约

| 操作 | 存储 |
|------|-----|
| Onboarding 完成 | `kOnboardingCompletedAt = Date()` （UserDefaults）|
| 跳过步骤记录 | `kOnboardingSkippedSteps = [Int]` （UserDefaults）|
| 登录项注册 | `SMAppService.mainApp.register()` + `kLoginItemEnabled = true` |
| preset 选择 | IPC `sieve.set_preset` → `AppState.preset` |

重触发条件（任一命中即进入 Onboarding）：
1. `kOnboardingCompletedAt == nil`（首次启动）
2. IPC 握手 `protocol_version` 不匹配
3. `sieve doctor` 关键检查失败（daemon 监听 / hook 注册）
4. 用户在设置 → About 主动触发

---

## 7. 错误与降级

| 条件 | 行为 |
|------|-----|
| `sieve setup` spawn 失败（PATH 问题）| 显示"找不到 sieve 命令"+ 引导手动检查 `$PATH` |
| `UNUserNotificationCenter` 被拒后用户想重新申请 | macOS 不允许重复申请被拒的权限；显示"请在系统设置→通知中开启" |
| `SMAppService.register()` 失败 | alert 错误 + 跳过（非必须权限）|
| Onboarding 期间 IPC 失联（daemon 不存在）| Step 2 直接显示 ✗；不阻断 Onboarding 进行 |

---

## 8. 性能与硬约束

| 指标 | 约束 | 来源 |
|------|------|------|
| 首次安装完成 | 5 分钟内完成全流程（含 sieve setup 耗时）| PRD §2.2 |
| 权限申请 | 必须走系统标准 API，不允许 osascript 绕开 | PRD §9 #8 |
| 登录项 | `SMAppService`（macOS 13+），不用老 API | CLAUDE.md 技术栈约束 |

---

## 9. 测试要求

- `kOnboardingCompletedAt == nil` → 断言 Onboarding 弹出
- Step 2：mock `sieve doctor` 全部 ✓ → 断言自动进入 Step 3
- Step 2：mock daemon 未安装 → 断言"未安装"提示 + 继续按钮禁用
- Step 2：mock 修复后重新检查全部 ✓ → 断言进入 Step 3
- Step 3：mock 通知权限授予 → 断言 ✓ 显示
- Step 4：mock `SMAppService.register` 成功 → `kLoginItemEnabled` 写入
- Step 5：选 Strict → IPC `sieve.set_preset{mode:"Strict"}` 调用验证
- Step 6：点完成 → `kOnboardingCompletedAt` 写入 + Onboarding 窗口关闭
- "跳过引导" → 确认 alert → `kOnboardingSkippedSteps` 记录跳过步骤
- protocol_version 不匹配 → 断言 Onboarding 被重触发

---

## 10. 未决事项（OQ）

| 编号 | 问题 | 当前选项 | 截止决策 |
|------|------|---------|---------|
| OQ-006-01 | Step 6 demo 的触发机制：向 daemon 发 canary 的接口是什么？ | 可能走 `sieve.evaluate` 或单独的 `sieve.trigger_canary`，待和 daemon 对齐 | Week 9 |
| OQ-006-02 | `sieve doctor` 的具体 5 项检查 CLI 输出格式是否有机器可读格式？ | 上游 SPEC-003 §4.1 需确认是否返回 JSON / 结构化输出，还是需要 GUI 解析文本 | Week 9 |

---

## 11. 变更记录

| 版本 | 日期 | 作者 | 变更 |
|------|------|-----|-----|
| v1.0 | 2026-05-02 | doskey | 首次起草 |
