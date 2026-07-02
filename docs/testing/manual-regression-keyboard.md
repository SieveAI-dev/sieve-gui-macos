# HIPS 键盘红线 · 人工回归清单

> Version: v1.0 — 2026-07-02
> 关联规格：SPEC-002（HIPS 弹窗）· 硬约束 #4（主按钮/Return 恒拒绝）
> 防回归目标：P0-2（Return 恒绑拒绝）· P0-3（red 阶段 ⌘+Click 摩擦门）· P0-1（Critical allow 强制 TouchID）

## 为什么是人工清单，而非 XCUITest

键盘红线的**状态机层**已由 `swift test` 编译期/单测期锚定（见下「自动化覆盖」）。**真键盘事件路径**（按下 Return/Space、系统认证弹窗）必须在运行中的 App 上验证，但当前不落 XCUITest，理由如下（均为硬技术约束，非省事）：

1. **c 断言不可脚本化**：Critical allow 的认证走 `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`，弹出的是**系统认证 sheet**（独立系统进程 UI）。XCUITest 无法向系统认证弹窗注入 Touch ID / 密码，用例会挂死在弹窗上。
2. **注入认证 stub 与红线冲突**：绕过系统 sheet 需给 `HipsPanelManager.criticalAuthenticator` 开注入缝，但该处有红线注释「不提供任何跳过认证的开关/环境变量」。开缝须先走设计决策（`#if DEBUG` 编译门 + Release 构建物理剔除旁路），属独立范围，本轮不做。
3. **真机焦点/激活语义需目视**：HIPS 弹窗是 `nonactivatingPanel` 浮窗，App 是 `LSUIElement` accessory；按钮 Tab 聚焦依赖系统 Full Keyboard Access（`AppleKeyboardUIMode`）。这些焦点语义在无头 CI / 后台环境无法可靠复现，需真人一次目视确认。
4. **基础设施成本 vs 收益**：XCUITest 还需新 UI target + 假 daemon UDS 桩 + `#if DEBUG` socket 注入 launch argument + 全按钮 `accessibilityIdentifier` + FKA 环境。而 a/b 的核心不变式已由「View 消费策略函数 + 编译期锚定」覆盖（见下），XCUITest 的边际收益主要落在「有人**故意**手写快捷键绕过策略」这一低概率回归上。

结论：a/b/c 的**逻辑不变式**下沉 `swift test`（编译期锚定，最强防线）；**真键盘事件**由本清单在真机 dogfood 时人工核验。若将来要覆盖第 4 点的残余风险，再按上述 target 方案补 XCUITest。

## 自动化覆盖（`swift test`，已随本轮落地）

| 断言 | 覆盖方式 | 测试位置 |
|---|---|---|
| a. Return 恒绑拒绝、允许类永不获 Return | View 的每个 footer 按钮 `keyboardShortcut` 改为 `HipsFooterPolicy.bindsReturnKey(role:)` 派生（不再手写）；矩阵测试锚定策略 | `HipsFooterPolicyTests.return_key_always_binds_to_deny` / `return_binding_by_role_pins_deny_only` |
| b. red 阶段键盘（任何快捷键）一律不放行允许 | `CmdClickGate.permitsAllow` 纯函数：`phaseRequiresCmdClick` 时须 `eventIsMouseClick && hasCommandModifier` | `CmdClickGateTests.red_phase_keyboard_never_allows` 等 |
| c. Critical 未认证不发 allow | `CriticalAllowGate.finalDecision/finalPerIssue`：认证闭包返回 false → 降级 deny（mock 注入） | `CriticalAllowGateTests.single_auth_failure_degrades_to_deny` 等 |

**编译期锚定的关键**：`HipsPopupView` 现在通过 `allowReturnShortcut`（恒 nil）/ `denyReturnShortcut`（恒 `.defaultAction`）两个策略派生属性挂快捷键。新增任何 footer 按钮若不经这两个属性、擅自手写 `.keyboardShortcut(.defaultAction)`，是 code review 红线；策略函数 `bindsReturnKey` 由矩阵测试守护。

## 人工回归步骤（真机 dogfood 时执行）

前置：真 daemon 运行（`~/.sieve/ipc.sock`），GUI 已连接（菜单栏非 disconnected）。用 `claude --bare -p "<触发 prompt>"` 或直接构造入站危险工具调用触发 HIPS 弹窗。

### A. Return 键恒落拒绝（P0-2）

对以下每种弹窗形态，聚焦弹窗后按 **Return**，断言**不产生任何 allow 应答**（观察 daemon 日志 / `sieve decisions` 无 allow，且弹窗行为等价点「拒绝」）：

1. 单 issue · 高置信 allow 推荐（允许按钮为视觉主选，蓝色）→ 按 Return → **拒绝**。
2. 单 issue · 无推荐 / 低置信（主按钮锁拒绝）→ 按 Return → **拒绝**。
3. 单 issue · 5s 内同 rule 二次弹窗（按钮换位 swapped）→ 按 Return → **拒绝**。
4. merged · 无 Critical（渲染「全部允许」，视觉主选）→ 按 Return → **拒绝全部**。
5. merged · 含 Critical（无「全部允许」，仅「仅允许非 Critical」+「拒绝全部」）→ 按 Return → **拒绝全部**。

预期：全部 5 种，Return 只触发拒绝侧，允许类按钮无论是否为视觉主选都不响应 Return。

### B. red 阶段 ⌘+Click 摩擦不被键盘绕过（P0-3）

让弹窗进入 red 阶段（倒计时剩余 ≤20%，允许按钮标签变为「按住 ⌘ 点击允许」）：

1. 键盘 Tab 聚焦到「允许」按钮 → 按 **Space** → **不放行**（无 allow 应答）。
2. 焦点在「允许」按钮 → 按 **Return** → **不放行**（Return 本就绑拒绝）。
3. 焦点在「允许」按钮 → 按 **⌘+Space / ⌘+Return** → **不放行**（键盘路径一律封死，`CmdClickGate` 只认鼠标事件）。
4. 鼠标**不带 ⌘** 点「允许」→ **不放行**。
5. 鼠标**带 ⌘** 点「允许」→ **放行**（唯一放行路径）。

预期：red 阶段允许仅经「带 ⌘ 的鼠标点击」放行，任何键盘组合都不放行。

### C. Critical allow 强制 TouchID（P0-1）

触发一个 Critical 严重度的入站危险决策：

1. 点「允许」（非 red 用普通点击；red 用 ⌘+Click）→ 弹出系统 Touch ID / 密码认证。
2. **取消认证** → 应答为 **deny**（降级），daemon 收到拒绝，`remember` 为 false。
3. 认证**失败**（错误指纹多次）→ 同样降级 **deny**。
4. 认证**通过** → 应答为 **allow**。
5. merged 含 Critical + 非 Critical，选「全部允许」→ 认证取消 → **仅 Critical 项降级 deny，非 Critical 项保持 allow**。

预期：Critical 的 allow 在认证未通过前绝不发送到 daemon；认证是发送 allow 的前置门，无跳过开关。

## 判定

上述 A/B/C 全部符合预期 = 键盘红线无回归。任一不符 → 记录形态 + 实际应答，按 P0 缺陷处理，勿发布。
