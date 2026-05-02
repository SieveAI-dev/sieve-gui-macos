# ADR 索引

> ADR (Architecture Decision Record) 记录本仓库的关键架构决策。
> 命名规则与生命周期见 [`../../DOCS-STANDARD.md`](../../DOCS-STANDARD.md) §2 §3 §5。

---

## 规则

- ADR 编号递增不跳号
- ADR 一旦发布（Status: Accepted）只允许追加 Consequences 实践反馈，**禁止**改写已发布的决策
- 决策被推翻 → 新写一个 ADR-MMM，旧 ADR 在头部加 `> Status: Superseded by ADR-MMM`
- 上游 daemon 仓库的 ADR（ADR-012/013/014/015/016/021）不在本索引，引用见 [`../../external/upstream-references.md`](../../external/upstream-references.md)

---

## Phase 1 决策清单

| 编号 | 状态 | 决策 | 标签 |
|-----|------|------|-----|
| [ADR-001](ADR-001-swiftui-native-only-stack.md) | Accepted | Phase 1 锁定 SwiftUI native，不引入跨平台层 | stack, build |
| [ADR-002](ADR-002-ipc-client-design.md) | Accepted | UDS + JSON-RPC 客户端基于 Network.framework | ipc |
| [ADR-003](ADR-003-window-scene-model.md) | Accepted | LSUIElement accessory + 多 Window scene + 浮窗 NSPanel | ui, app |
| [ADR-004](ADR-004-hips-floating-panel.md) | Accepted | HIPS 弹窗用 NSPanel + .floating + canJoinAllSpaces + fullScreenAuxiliary | ui, hips |
| [ADR-005](ADR-005-audit-db-read-only.md) | Accepted | SQLite.swift 只读直连 audit.db + DispatchSource file watch | data, history |
| [ADR-006](ADR-006-i18n-string-catalogs.md) | Accepted | macOS 14+ String Catalogs，zh/en 双语 | i18n |
| [ADR-007](ADR-007-theme-system-vs-override.md) | Accepted | system / 强制 light / 强制 dark 三档主题 | ui, theme |
| [ADR-008](ADR-008-touchid-unlock-session.md) | Accepted | LAContext + 5 分钟解锁会话保护敏感字段 | security |
| [ADR-009](ADR-009-project-layout-single-target.md) | Accepted | Phase 1 单 Xcode target + 文件夹分模块 | build |
| [ADR-010](ADR-010-distribution-sparkle-notarization.md) | Accepted | Sparkle EdDSA + Apple notarization 双签 | release |
| [ADR-011](ADR-011-redact-on-export.md) | Accepted | 诊断包导出走统一脱敏管线 | security, privacy |

---

## 标签说明

| 标签 | 含义 |
|------|-----|
| `stack` | 技术栈选择 |
| `build` | 构建/工程结构 |
| `ipc` | IPC 通信 |
| `ui` | 用户界面 |
| `app` | 应用进程模型 |
| `hips` | HIPS 弹窗专属 |
| `data` | 数据访问/存储 |
| `history` | 历史窗口 |
| `i18n` | 国际化 |
| `theme` | 主题/外观 |
| `security` | 安全相关 |
| `privacy` | 隐私相关 |
| `release` | 发布/分发 |
