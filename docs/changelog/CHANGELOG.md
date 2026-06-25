# Changelog

> 格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) + Conventional Commits
> 版本号语义：semver；BREAKING 改动主要由协议 bump 触发

---

## [Unreleased] — 2026-05-12

### 基础设施
- 域名迁移 `sieve.local` → `sieveai.dev`
  - Sparkle `SUFeedURL`：`updates.sieve.local` → `updates.sieveai.dev`（`Info.plist` + `project.yml`）
  - `appcast.xml` link / enclosure url 同步
  - `UpdatesSettingsView` About 段三个链接（docs / 反馈 / 开源声明）同步
- 补 `LICENSE` 与 `SECURITY.md`

### unix-style 协议适配（多 listener + 协议术语中性化）
- `HealthResultDTO` 全量重写，对齐 SPEC-005 §9.5 schema
- 新增 `ListenerSnapshot { addr, port, provider_id, protocol }` + `effectiveListeners` 兼容访问器
  （优先 `listeners[]`，旧 daemon 退化到 `listen` 单值）
- `DaemonSettingsView` 加 "Listeners" 段；首次进入自动拉一次 `sieve.health`
- `OnboardingView.runDoctor` 基于真实 health 字段构造 5 项 checks
- 新增 `HealthResultDTOTests`（完整字段 / 旧 daemon 兼容 / 暂停态 / custom preset / id 派生 / 必填缺失 / 非法时间戳）
- 协议契约：未 bump `protocol_version`（v2 内向后兼容扩展）；wire 字段 / method 名全部保留
- 文档同步：`docs/external/upstream-references.md` 补多 listener 与协议术语中性化契约；
  `docs/api/ipc-protocol.md` v2.0 → v2.1，加 §12 listeners[] 实现注解 + §13 协议术语中性化影响说明

## [Unreleased] — 2026-05-04

### 文档（联调阶段）
- 新增联调测试 checklist，覆盖手动联调全部场景：协议握手 / HIPS / 三态决策 / 菜单栏 / Settings 六 Tab / History / Debug 四 Tab / Onboarding 6 步 / Toast / 重连 / v2 兼容扩展 / OUT/IN 规则 / 安全红线 / 性能预算
- 每项含操作步骤 / 触发条件 / 预期效果 / 失败排查路径

## [Unreleased] — 2026-05-03

### 协议侧（SPEC-005 v2 上游同步，BREAKING）
- protocol_version "v1" → "v2" 全仓硬编码刷新（IPCClient 白名单、SPEC-008 文档、相关测试）
- GUI → daemon 业务错误码段位升级 -32100/101/102（user_canceled_via_window_close / gui_render_failed / gui_shutdown_during_decision）
- decision_response.result 补 required 字段：request_id / decided_at / by_user / ui_phase_when_clicked
- responded_at 字段名改为 decided_at
- inflight 重连行为反向（§3.4）：丢弃 stale inflight 而非重发
- HelloParams 加 daemon_boot_id + 三路 toast（首次连接 / daemon 重启 / 仅断连）
- preset_changed/paused_changed 回声判定换 origin_request_id 集合（多 GUI 场景下可靠）
- Disposition / DefaultOnTimeout / NotifyKind / Preset 枚举 snake_case
- EvaluateResult / GraylistEntry / SetPausedResult / ReloadConfigResult 字段对齐 SPEC §9
- IPCOutbound 参数 [String: Any] → Encodable（禁透传）
- context_hint 截断改 unicodeScalars.prefix(200)，UI 层阻止超限输入

### 协议侧（SPEC-005 v2.0+ 兼容扩展接通）
- sieve.list_rules GUI 端：Settings Detection 规则总览 Table + 错误降级 -32006/-32601
- sieve.purge_history GUI 端：Touch ID 二次确认 + 错误降级 -32007/-32601
- sieve.set_preset_overrides 接通：Custom 模式内联 timeout/default 编辑（500ms debounce + 乐观回滚）

### Phase 1B HIPS UX
- 5s 按钮位置互换（denyTracker）防止肌肉记忆误按
- EIP-712 typed_data 解析渲染（domain/chainId/verifyingContract + primaryType + message 字段表）
- 复制原始 JSON 按钮 + 二次确认 alert（DEBUG only）+ 5s 后清空剪贴板
- reduce-motion 适配（HIPS + Toast 动画 duration=0，颜色保留）
- 失联期间 disconnectedCache 路径完整性测试
- 渲染失败降级：系统通知 + auto-deny IPC -32101

### Phase 1B 系统集成
- Settings critical_lock 规则行 disabled + tooltip
- History CSV/NDJSON 导出（流式 + 取消 + 导出强制脱敏）
- Debug 实时事件 grep 200ms 去抖 + 暂停快照
- Debug IPC 监视详情面板（method/id/bytes/timestamp，永不展示 params）
- Onboarding step 6 demo 触发真实 sieve.evaluate
- SMAppService 注册错误 alert + Settings General banner
- DiagnosticPackager audit.db 脱敏拷贝（evidence 列清空）+ ZIP 打包

### Phase 1C 发布前
- Sparkle appcast.xml 模板 + EdDSA 公钥占位
- .dmg 打包脚本（hdiutil + codesign）+ notarytool stapler 流程
- String Catalogs (Localizable.xcstrings) 关键 UX 文案 30+ 抽离（Xcode 14+ 中文 key 特性）

### 跨 Tab
- History → Debug Tab "在调试窗口重放" 联动

### 测试基础设施
- `MockDaemonHarness`（测试内 IPC 端点：sendNotification/Request + 连接计数 + waitForNewConnection）
- IPCClient 集成测试 5 场景（握手 / 版本不识别 / 重连丢 inflight / boot_id 三路 / request_decision 双格式）

### 修复
- HipsPanelManager auto-deny 通知调用修正（UI 层错误经 xcodebuild warnings-as-errors 暴露）
- IPCClient 集成测试稳定性：sleep 替换为 waitForNewConnection
- versionMismatch 状态序列断言修正：检查 versionMismatch 之后无 connecting/retrying
