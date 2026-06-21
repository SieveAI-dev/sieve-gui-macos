# Sieve GUI macOS — PROGRESS

> 单一进度真实源。上次更新：2026-06-20
> 全量历史见 `_archive/todo.md`（Phase 0/1A）。本文件 P0/P1 基于 2026-06-20 全模块代码盘点（代码实际为准，已纠正 todo 过时勾选）。

---

## 当前阶段（一句话）

Phase 1A 骨架 + 核心红线已落地并经 Xcode 26.5 / Swift 6.3.2 构建+测试验证；Phase 1B 大量项经盘点确认**已完成**，剩余真实缺口集中在 HIPS 失联/合并决策、i18n 接线、导出、测试四块。

---

## ✅ 已完成（盘点确认，超出 todo 描述）

- **HIPS**：`typed_data` EIP-712 解析渲染（EIP712View+Parser）/ 同 rule_id deny 后按钮互换（HipsDenyTracker）/ reduce-motion 闪烁抑制 / 四条核心红线（Remember 不渲染、主按钮锁拒绝、含 Critical 隐藏全部允许、400ms swallow）
- **Settings**：`sieve.list_rules` / `set_preset_overrides` / `purge_history` 三方法客户端骨架 + critical_lock 禁编 + Touch ID 清空历史 + SMAppService 错误反馈 UI
- **系统集成**：DiagnosticPackager audit.db 脱敏拷贝（manifest+脱敏列）/ TouchID 解锁会话 + 锁屏清会话
- **2026-06-20 P0 完成：HIPS 失联 `disconnectedCache` 完整路径（SPEC-002 §6 场景 D）** — TDD 核心库 `DisconnectedDecisionCache`（入队/去重/重发-清空，5 测试 red→green）+ `HipsPanelManager` 接线（失联缓存、重连握手 `resendDisconnectedDecisions`）+ `HipsPopupView` 失联 banner
- **2026-06-20 baseline**：`xcodebuild build` BUILD SUCCEEDED 0 warning；`swift test` **181/181（34 suites）**

---

## 🚧 进行中（≤3）

- 下一 P0：HIPS 多 issue 合并部分允许（SPEC-002 §4.8，merged 决策路径）；或先做「复制 JSON 移出 `#if DEBUG`」（S，快）

---

## ⏭ 下一步（按优先级，可勾选）

> 标注：**[核心库]** 可走 `swift test` 验证；**[UI]** 需 `xcodebuild`（Features 层被 Package.swift exclude）。

### P0 — 红线缺口，不依赖 daemon

- [x] **HIPS 失联 `disconnectedCache` 完整路径**（SPEC-002 §6 场景 D）— ✅ 2026-06-20：`DisconnectedDecisionCache` 核心库 TDD（5 测试）+ `HipsPanelManager` 接线 + 失联 banner；181 测试 + BUILD SUCCEEDED
- [x] **HIPS 多 issue 合并部分允许 UI**（SPEC-002 §4.8）— ✅ 2026-06-20：核心库 `MergedDecisionBuilder`（denyAll/allowAll/allowNonCritical → per-issue，6 测试 red→green）+ `HipsPopupView` merged 三按钮组（红线：含 Critical 禁渲染"全部允许"，用 `canAllowAll` 判断）+ `HipsPanelManager.handleMergedDecision`（→ `MergedDecisionResponse`，失联复用 `.merged` 缓存路径）；187 测试 + BUILD SUCCEEDED 0 warning。**未做（后续打磨，非红线）**：issue 折叠/展开（Critical 默认展开）、per-issue remember checkbox
- [x] **HIPS「复制原始 JSON」移出 `#if DEBUG`**（SPEC-002 §4.4）— ✅ 2026-06-20：三处（state/alert/copyRawJSON）移出 DEBUG + footer 最左正式按钮（二次确认 + 5s 清剪贴板）+ 删右上角调试 overlay；BUILD SUCCEEDED 0 warning（待提交）

### P1 — SPEC 功能缺口，不依赖 daemon

- [ ] History CSV/NDJSON 导出 + 进度 + 取消（强制脱敏 ADR-011，L，missing）**[UI]**
- [ ] History 「在调试窗口重放」联动（M，missing）/ schema v2 字段 fail-soft 显「—」（S，partial）
- [ ] Debug 实时事件 grep 暂停独立快照（M，partial，恢复后有竞态）/ IPC 详情面板点行展开（S，partial）
- [ ] Onboarding 关闭按钮 + 「跳过引导?」alert（S，missing）
- [ ] Toast/CountdownView 接 `reduceMotionOverride`（system/always/never 当前是死设置，S，missing）
- [ ] Settings 窗口 720×540 → SPEC 760×600（S）/ Daemon Tab 补重启/audit.db 大小/Finder 入口（M）
- [ ] Sparkle `SUPublicEDKey` 占位 → 真实 EdDSA 公钥（S，需生成 keypair，私钥离线，**待用户提供密钥材料**）

### P1 — 测试债

- [ ] HIPS 弹窗 UI 行为测试（Phase3 swallow / 锁拒绝 / checkbox 不渲染，现有仅 Model 层等价断言）**[UI]** ViewInspector/XCUITest
- [ ] IPCClient mock daemon harness 集成测试（重连退避/版本不识别/30s 心跳，L）**[核心库]**
- [ ] AuditDBReader v1/v2 schema fixture 兼容测试（M）**[核心库]**
- [ ] CI GitHub Actions matrix（macOS 13/14）`swift test` + `xcodebuild` + swift-format lint（M）

### P2 — 依赖真 daemon 端到端验证 / 上游新 API

- [ ] Settings 三方法端到端联调（list_rules/set_preset_overrides/purge_history 已实现，需真 daemon 验）
- [ ] Settings Custom 表格 knownRules 假数据 → 打通 list_rules liveRules
- [ ] Debug 系统状态 4 卡接真实 `sieve.health` + audit.db 大小
- [ ] Onboarding step6 demo 触发真实 `sieve.evaluate` HIPS 演示

---

## 🚫 阻塞 / 等决策

- **验证手段**：核心库逻辑走 `swift test`，Features/UI 层走 `xcodebuild`（Features 被 `Package.swift` exclude，无法单测）。
- ⚠️ **P1 部分项需复核真实状态**：测试目录已存在 `IPCClientIntegrationTests` + `MockDaemon/`、`HistoryExportFormatterTests`、`ToastReduceMotionTests`，对应「mock daemon 集成 / History 导出 / Toast reduce-motion」可能已部分完成；开工前先读真实文件确认（早期盘点对完成度的判断不完全可靠）。
- **Sparkle EdDSA 公钥**：需用户提供真实 keypair（私钥离线保管），代码侧仅占位替换。
