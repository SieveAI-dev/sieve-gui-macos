# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。

> 写作约定：
> - 每个版本下分 `Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security` 六类
> - 影响 IPC 协议的变更必须额外标注 `protocol_version` 变化
> - Phase 0（文档体系）期间，进度由 `tasks/todo.md` 跟踪，不在此处记录

---

## [Unreleased]

### Added

- **域名迁移 `sieve.local` → `sieveai.dev`（跟进上游 ADR-030）**
  - Sparkle `SUFeedURL`：`updates.sieve.local` → `updates.sieveai.dev`（`Info.plist` + `project.yml`）
  - `appcast.xml` link / enclosure url 同步
  - `UpdatesSettingsView` About 段三个链接（docs / 反馈 / 开源声明）同步
- **`LICENSE` 与 `SECURITY.md` 补齐**

- **Phase 1D：unix-style 协议适配（ADR-026 + ADR-028）**
  - `HealthResultDTO` 全量重写，对齐 SPEC-005 §9.5 真实 schema（之前是 `ok/checks/metrics{p99/throughput/goroutines}` 早期 mock 占位，从未真联调）
  - 新增 `ListenerSnapshot { addr, port, provider_id, protocol }` 与 `effectiveListeners` 兼容访问器（优先 `listeners[]`，旧 daemon 退化到 `listen` 单值）
  - `DaemonSettingsView` 加 "Listeners" 段，渲染 multi-listener；首次进入自动拉一次 `sieve.health`
  - `OnboardingView.runDoctor` 基于真实 health 字段构造 5 项 checks（替换占位）
  - 新增 `HealthResultDTOTests`（7 个 case：完整字段 / 旧 daemon 兼容 / 暂停态 / custom preset overrides / id 派生 / 必填缺失 / 非法时间戳）
  - 测试基线：127 → 134（+7）
  - **协议契约**：未 bump `protocol_version`（v2 内向后兼容扩展）；wire 字段 `gui_popup` / method 名 `sieve.request_decision*` 全部保留向后兼容（ADR-028 选择最大兼容路径）
- **Phase 1A 完成**：49 个 Swift 源文件 / 5593 行；`xcodebuild` 干净通过；20/20 单元测试全绿
- 单 Xcode target 工程骨架（`project.yml` + XcodeGen），目录布局符合 [ADR-009](docs/design/adr/ADR-009-project-layout-single-target.md)
- Models 层全套：HipsRequest 五模板解码 + 编码层强制 `remember=false` 红线
- IPC 客户端：`Network.framework` UDS + 退避 1/2/5/10/30s + 30s 心跳超时 + 协议版本白名单 + `InflightQueue` actor + `sendRequest async throws -> Data`
- audit.db 只读 + DispatchSource file watch + v2 schema fail-soft
- AppState `@MainActor` 单例 + 状态优先级（disconnected > hold > paused > warning > normal）
- UI Components：`MaskedField`（敏感字段唯一渲染入口）/ `SeverityChip` / `CountdownView` / `DisconnectedBanner`
- 菜单栏 + Quick Menu（五状态图标 + 暂停 picker ≤30 分钟 + hold 倒计时角标）
- HIPS 浮窗 + 5 种 DetailCard：400ms swallow / Phase3 ⌘-Click / `allow_remember=false` 不渲染 checkbox / 主按钮锁拒绝 / 多 issue 含 critical 禁「全部允许」/ rawJSON 关闭即清
- Toast + 系统通知（NotificationCenterAdapter）
- Settings 六 Tab：General / Detection Preset / Privacy & Data / Daemon / Updates / About
- History 窗口 + Inspector + Touch ID 5 分钟解锁会话（锁屏唤醒清会话）
- Debug 四 Tab：实时事件 ring buffer (1000) / 规则评估 / IPC 监视 ring buffer (100，params 列硬显「不展示」) / 系统状态
- Onboarding 6 步（`NSApp.beginModalSession` + 100ms pump 不阻塞主 RunLoop）
- DiagnosticPackager 强制脱敏导出
- Sparkle bridge（无网络入口接入决策路径）
- 单元测试覆盖：HipsRequestDecoder / DecisionResponse 编码层强制 / Recommendation 主按钮锁 / IPC 消息编解码 / InflightQueue waiter resume+throw / UserSettings clamp

### Notes

- 协议版本：`v1`（IPC 客户端硬编码白名单 `["v1"]`，不识别终态 versionMismatch）
- macOS 13+，Apple Silicon + Intel 通用，`SWIFT_STRICT_CONCURRENCY=complete`
- 入站决策路径不联网（entitlements `com.apple.security.network.client = false`）
- 详细进度见 [`tasks/todo.md`](tasks/todo.md)，本轮踩坑沉淀见 [`tasks/lessons.md`](tasks/lessons.md) L-011~L-016

---

## [0.0.1] — 2026-05-02

### Added

- 项目初始化
- Phase 0 文档体系落地（34 个文件）
  - PRD v1.0、DOCS-STANDARD v2.0、glossary
  - architecture.md、data-model.md
  - 11 个 ADR
  - 8 个 SPEC + IPC 协议参考 (`docs/api/ipc-protocol.md`)
  - 开发与发布指南 (`docs/guides/`)
  - 上游引用 (`docs/external/upstream-references.md`)
  - 经验沉淀 (`tasks/lessons.md`)
- Git 必备文件（`.gitignore` / `.gitattributes` / `.editorconfig` / `.github/`）

### Notes

- 协议版本：尚未实现，目标 `v1`
- 代码尚未开工
