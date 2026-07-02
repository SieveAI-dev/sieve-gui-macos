# Changelog

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。

> 写作约定：
> - 每个版本下分 `Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security` 六类
> - 影响 IPC 协议的变更必须额外标注 `protocol_version` 变化

---

## [Unreleased]

### Added

- **多 listener 协议适配** — `HealthResultDTO` 对齐 SPEC-005 的 health schema；新增 `ListenerSnapshot { addr, port, provider_id, protocol }` 与 `effectiveListeners` 兼容访问器（优先 `listeners[]`，旧 daemon 退化到 `listen` 单值）；`DaemonSettingsView` 新增 "Listeners" 段渲染 multi-listener，首次进入自动拉一次 `sieve.health`；`OnboardingView.runDoctor` 基于真实 health 字段构造诊断检查项
- **域名迁移 `sieve.local` → `sieveai.dev`** — Sparkle `SUFeedURL`、`appcast.xml` link / enclosure url、`UpdatesSettingsView` About 段链接同步
- **`LICENSE` 与 `SECURITY.md` 补齐**
- 单 Xcode target 工程骨架（`project.yml` + XcodeGen）
- Models 层：HipsRequest 五模板解码 + 编码层强制 `remember=false` 红线
- IPC 客户端：`Network.framework` UDS + 指数退避 + 心跳超时 + 协议版本白名单 + `InflightQueue` actor + 请求超时清扫（`TimeoutPolicy`）
- audit.db 只读 + DispatchSource file watch + v2 schema fail-soft
- AppState `@MainActor` 单例 + 状态优先级（disconnected > hold > paused > warning > normal）
- UI Components：`MaskedField`（敏感字段唯一渲染入口）/ `SeverityChip` / `CountdownView` / `DisconnectedBanner`
- 菜单栏 + Quick Menu（五状态图标 + 暂停 picker ≤30 分钟 + hold 倒计时角标）
- HIPS 浮窗 + 5 种 DetailCard：误点吞噬窗口 / `allow_remember=false` 不渲染 checkbox / 主按钮锁拒绝 / 多 issue 含 critical 禁「全部允许」/ 原始 JSON 关闭即清
- Toast + 系统通知（NotificationCenterAdapter）
- Settings 六 Tab：General / Detection Preset / Privacy & Data / Daemon / Updates / About
- History 窗口 + Inspector + Touch ID 解锁会话（锁屏唤醒清会话）
- Debug 四 Tab：实时事件 / 规则评估 / IPC 监视（params 列恒显「不展示」）/ 系统状态
- Onboarding 引导流程（不阻塞主 RunLoop）
- DiagnosticPackager 强制脱敏导出
- Sparkle bridge（无网络入口接入决策路径）

### Fixed

- **menu-bar**：修复菜单栏状态机自指守卫导致握手成功后图标卡失联——改用独立 `ipcConnected` 事实位
- **menu-bar**：暂停期间「Critical 拦截仍然生效」文案移到暂停两分支共用
- **toast**：`reduceMotionOverride`（system/always/never）接入 ToastController，不再仅读系统 flag
- **settings**：General 主题/语言改动即时生效（主题切 `NSApp.appearance`，语言写 `AppleLanguages` + 重启提示）；灰名单删除加确认 alert + 失联禁用 + 删后刷新
- **history**：schema 未知 banner 接 `AppState.setAuditSchemaWarning`；分页触底翻页接 Detail cell `.onAppear`；列表与 Inspector 统一脱敏判定（`HistoryMaskPolicy.contentUnlocked` 单一真实源，解锁态敏感字段走 `MaskedField`）
- **debug（Security）**：规则评估改 `EvaluateResult` DTO 结构化渲染 + 命中摘要走 `MaskedField`(locked) + 切 Tab/关窗清空（决策路径不持久化命中原文）
- **ipc**：`EvaluateResult.Match.severity` 改 optional + tolerant 解码，避免枚举外取值致整结果解码失败
- **debug**：IPC 监视 inflight 统计接 IPCClient 只读 `inflightCount`

### Notes

- 协议版本：`v2`（IPC 客户端协议版本白名单仅 `["v2"]`，不识别即终态 disconnected）
- macOS 13+，Apple Silicon + Intel 通用，`SWIFT_STRICT_CONCURRENCY=complete`
- GUI 决策路径不发起网络请求（架构约束：HIPS/决策链路不引用任何网络客户端，网络出口仅 Sparkle 更新且与决策路径隔离。注：App 未启用 App Sandbox，entitlements 的 `network.client = false` 表意图而非 OS 强制）

---

## [0.1.0-alpha] — 2026-05-02

### Added

- 项目初始化
- 文档体系落地
  - PRD、DOCS-STANDARD、glossary
  - architecture.md、data-model.md
  - 8 个 SPEC + IPC 协议参考 (`docs/api/ipc-protocol.md`)
  - 开发与发布指南 (`docs/guides/`)
  - 上游引用 (`docs/external/upstream-references.md`)
- Git 必备文件（`.gitignore` / `.gitattributes` / `.editorconfig` / `.github/`）

### Notes

- 协议版本：目标 `v2`
