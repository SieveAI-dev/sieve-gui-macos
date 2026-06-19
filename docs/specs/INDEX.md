# SPEC 索引

> SPEC (Specification) 记录每个模块的完整功能技术规格。
> 命名规则与模板见 [`../DOCS-STANDARD.md`](../DOCS-STANDARD.md) §2 §4。

---

## 规则

- SPEC 编号与 ADR 不共用编号空间
- SPEC 文件内带 `Version: vX.Y` 标注；不兼容修改递增 minor 版本（v1.0 → v1.1）
- 发布版本对应的 SPEC 状态标 `Frozen`，禁止任何修改；下个版本另开新文件
- IPC 字段细节统一在 [`../api/ipc-protocol.md`](../api/ipc-protocol.md)，SPEC 不复述只引用

---

## Phase 1 SPEC 清单

| 编号 | 状态 | 模块 | PRD 章节 |
|-----|------|------|---------|
| [SPEC-001](SPEC-001-menu-bar-and-quick-menu.md) | Stable | 菜单栏 + Quick Menu | §5.1 |
| [SPEC-002](SPEC-002-hips-popup-window.md) | Stable | HIPS 弹窗（GUI 渲染规格）| §5.2 |
| [SPEC-003](SPEC-003-settings-window.md) | Stable | 设置窗口 6 个 Tab | §5.3 |
| [SPEC-004](SPEC-004-history-window.md) | Stable | 历史窗口 + Touch ID + 导出 | §5.4 |
| [SPEC-005](SPEC-005-debug-window.md) | Stable | 调试窗口 4 个 Tab | §5.5 |
| [SPEC-006](SPEC-006-onboarding-flow.md) | Stable | 6 步引导 + 权限矩阵 | §5.6 |
| [SPEC-007](SPEC-007-toast-and-system-notifications.md) | Stable | 状态栏 Toast + macOS 通知 | §5.7 |
| [SPEC-008](SPEC-008-ipc-client.md) | Stable | GUI 侧 IPC 客户端实现 | §6 |

---

## 与上游 SPEC 的关系

| 本仓库 SPEC | 上游对应 | 边界 |
|------------|---------|-----|
| SPEC-002 | 上游 SPEC-002 (hips-popup-behavior) | 上游定义 IPC 行为契约；本仓库定义 GUI 渲染规格。两者必须同步演进 |
| SPEC-006 | 上游 SPEC-003 (sieve-setup-tool) | 上游定义 `sieve setup`/`doctor` CLI 行为；本仓库定义 Onboarding 如何调用与展示结果 |
| SPEC-008 | 上游 ADR-013 (ipc-protocol) | 上游定义协议；本仓库定义 GUI 侧客户端实现 |

详见 [`../external/upstream-references.md`](../external/upstream-references.md)。
