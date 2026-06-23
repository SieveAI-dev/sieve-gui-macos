# Sieve GUI macOS — PROGRESS

> 单一进度真实源。上次更新：2026-06-23（基于 10-agent ground-truth 全模块盘点纠偏，取代 06-20 勾选）。
> 全量历史见 `_archive/todo.md`（Phase 0/1A）。本次基于 10-agent ground-truth 全模块盘点。

---

## 当前阶段（一句话）

**批次 A + C + D 全部完成并验证**（swift test **228/41** + xcodebuild **BUILD SUCCEEDED**）：死链清理 9 项 + 红线收口（Debug evidence 跨仓确认真 P0 已脱敏 / IPC inflight 超时 / 系统通知 / Onboarding / GUILog atomic）+ 测试债（AuditDB 8 测试 / HIPS phase 纯函数 / 假信心修复）。全部安全红线全绿。**剩余仅依赖外部**：批次 B 真机 GUI dogfood（需启动真 daemon）+ 批次 E 发布前置（需离线 keypair）+ 3 个 follow-up（C3 HipsPending HIPS 侧接线 / History loadMore >200 行窗口 / Privacy remove_graylist 真机确认）。

---

## ✅ 已完成（2026-06-23 盘点确认）

### 安全红线全绿（已验证 file:line）
- **HIPS 8 条**：allow_remember=false 不渲染 checkbox / 主按钮缺 recommendation·非 high 锁拒绝 / 含 Critical 隐藏「全部允许」/ rawJSON 关闭即清 / 编码层 remember 强制 false / Phase3 ⌘-Click / 0.4s swallow / 串行排队
- **IPC 5 条**：v2 白名单硬拒不嗅探 / remember 编码层强制 / Codable 不透传 / 不假装健康 / 决策路径不联网
- **横切**：导出强制脱敏 / Touch ID 二次确认 / critical_lock 禁编 / IPC params 永不展示 / GUI 只读 audit.db

### PROGRESS 6-20 低估、实际已落地（纠偏）
- mock daemon harness 集成测试（IPCClientIntegrationTests + MockDaemonHarness 真 socket）
- History CSV/NDJSON 导出 + 强制脱敏 + 进度 + 取消（HistoryExporter + 9 测试）
- Toast reduce-motion 测试 / 合并部分允许 / 失联缓存重连重发 / 复制 JSON 移出 #if DEBUG
- CI 三 job matrix（macos-13/14 swift test + xcodebuild + swiftformat）
- 81-fixture 跨仓 schema 一致性 / Daemon Listeners 段 / EIP-712 typed_data 渲染
- swift test = **187 tests / 35 suites 全绿**（23 测试文件 / 222 @Test）

---

## 🚧 进行中（≤3）

- ✅ 批次 A/C/D 全部完成（所有 depends_on_daemon=false 项已闭合）。**剩余仅需外部动作**：批次 B 真机 dogfood（你起 daemon）+ 批次 E Sparkle keypair（你提供离线私钥）

---

## ⏭ 下一步（按优先级，可勾选）

> 标注：**[核心库]** swift test 可验；**[UI]** 需 xcodebuild（Features 被 Package.swift exclude，swift test 不编 UI）。

### 批次 A — 死链清理（depends_on_daemon=false）✅ 全部完成 2026-06-23

> 验证：swift test **197/37 全绿** + xcodebuild **BUILD SUCCEEDED** + 红线抽查（MenuBar 文案 / History MaskedField+脱敏一致）通过。后 6 项经并行子代理实现（互斥文件边界）。

- [x] ⭐ **MenuBar 状态机死锁** — 引入独立 `ipcConnected` 事实位替代自指守卫；AppState 纳入 swift test + 6 回归测试 red→green
- [x] **Toast reduceMotionOverride 死设置** — UserSettings 加纯函数 `reduceMotionEnabled(systemReduceMotion:)`，ToastController 消费 override（+4 测试）
- [x] **General 主题/语言死值** — 主题 onChange→NSApp.appearance 即时生效；语言写 AppleLanguages + 重启提示
- [x] **History schema banner 死值** — reader.schemaWarning→`AppState.setAuditSchemaWarning` 回写（onAppear+onChange 驱动 banner）
- [x] **History loadMore 死代码** — Detail cell `.onAppear` 末行触底翻页 + loading/reachedEnd 双 guard
- [x] **History 脱敏不一致** — 抽 `HistoryMaskPolicy.contentUnlocked` 单一真实源；caller_pid/evidence_meta 解锁态改走 MaskedField（红线）
- [x] **MenuBar 暂停 Critical 文案消失** — 文案提到 pause if/else 两分支共用（红线，SPEC-001 §4.2）
- [x] **灰名单删除无确认** — 加确认 alert + 失联禁用 + 改带响应 sendRequest 删后刷新
- [x] **Debug inflight 死卡** — IPCClient 加只读 `inflightCount`，IPCMonitorTab 1s Timer 刷新（IPC 核心零改）

> ⚠️ 遗留风险（非阻塞，纳入批次 B/C 复核）：History loadMore >200 行 offset 漂移（SPEC 既定 200 内存窗口，未重构）；Privacy `remove_graylist` 改带响应需真机确认 daemon 是否回响应（否则卡 inflight）。

### 批次 B — 真机 GUI dogfood（解锁所有 depends_on_daemon 项）

- [ ] 修死锁后跑真机 GUI dogfood：连真 daemon 验 hello 握手 / sieve.health（Debug 4 卡 + Daemon Tab）/ list_rules（Settings Custom 表）/ sieve.evaluate（Onboarding demo + Debug 规则评估）/ HIPS 全链路
- [ ] Settings Custom 表 knownRules 假数据 → list_rules liveRules（真机验）
- [ ] Debug 系统状态 4 卡接真实 sieve.health（响应当前被 `_=try?` 丢弃）
- [ ] Toast 点击跳历史死链（wire 缺 audit_event_id，需 daemon 补或退化打开最新历史）

### 批次 C — 红线收口 + 功能缺口 ✅ 完成 2026-06-23（C3 HipsPending 遗留 HIPS 侧）

> 验证：swift test **228/41** + xcodebuild **BUILD SUCCEEDED**。7 切片并行 + 主上下文修 2 处（D6 测试标记泄漏、C1 暴露的 Severity unknown 跨仓缺口）。

- [x] **Debug 规则评估红线脱敏** — 跨仓确认**真 P0**（daemon handle_evaluate 对非 critical_lock 命中回填 32 字节原 payload 到 matched_pattern_summary）；改 EvaluateResult DTO 结构化渲染 + matched_pattern_summary 走 MaskedField(locked) + onDisappear 清空。附带修 `Severity` unknown 跨仓缺口（Match.severity→optional + tolerant）
- [x] **IPC InflightQueue 超时清扫** — TimeoutPolicy(60s/evaluate 90s) + sweepTimeouts + IPCClient 5s 周期 sweep + 6 测试（IPC 核心零改）
- [~] **系统通知接线** — notifyDisconnected/notifyReconnected 接 AppStateIPCAdapter（去抖）；**HipsPending 遗留**：信号源在 HipsPanelManager（HIPS 侧），需后续接线
- [x] **Onboarding 4 项** — 关闭按钮+确认 alert（WindowManager .closable + NSWindowDelegate）/ 跳过写 kOnboardingSkippedSteps / 未安装降级（which+候选路径+socket）/ 测试
- [x] **GUILog atomic（额外）** — 持久 O_APPEND fd（内核保证单 write 原子追加）+ rotate 前 close + 注释澄清硬约束#8 边界

### 批次 D — 测试债 ✅ 完成 2026-06-23

- [x] **AuditDBReader 测试** — 新增 `open(path:)` 注入（可测性改进）+ 8 测试调真实 reader（v1/v2 schema / schemaWarning / 增量 / fail-soft / filter）
- [x] **HIPS currentPhase 假信心** — 提取 `HipsPhase.resolve(remaining:total:)` 纯函数（核心库唯一权威）+ HipsPopupView 改用 + 测试调真函数（消除内联重写漂移盲区）
- [x] **ToastReduceMotion 假信心** — 已由批次 A 解决（ReduceMotionResolveTests 调真函数 reduceMotionEnabled）

### 批次 E — 发布前置

- [ ] Sparkle SUPublicEDKey PLACEHOLDER → 真实 EdDSA 公钥（project.yml:68 + config/Info.plist 两处，私钥离线，依赖更新服务端部署就绪）
- [ ] Telemetry GUI 侧落点确认（对 PRD；可能主要在 daemon/updater 侧）

---

## 🚫 阻塞 / 等决策

- **批次 B 真机 dogfood（待你起 daemon）**：所有 depends_on_daemon 项（list_rules liveRules / sieve.health 4 卡 / evaluate / HIPS 全链路）需连真 daemon 验证；死锁已修，可联调。
- **批次 E Sparkle EdDSA 公钥（待你提供 keypair）**：私钥离线，依赖更新服务端部署就绪。
- ✅ ~~Debug evidence 红线等级待跨仓确认~~ → 已跨仓确认**真 P0**（daemon 非 critical_lock 命中回填 32 字节原文）并完成脱敏（C1）。
- **follow-up（非阻塞）**：C3 HipsPending 需 HipsPanelManager 接线 / History loadMore >200 行 offset（SPEC 既定窗口）/ Privacy `remove_graylist` 真机确认 daemon 回响应。
- **验证手段**：核心库走 swift test；Features/UI 层改动必须 xcodebuild（本机 Xcode 26.5 可编）。
