# 上游引用 — Sieve daemon 仓库

> 本仓库（`sieve-gui-macos`）严格依赖上游 Rust daemon 仓库（`sieve`）的若干契约。
> 上游文档**不复制**到本仓库；本文件只列出依赖项 + 说明依赖的是哪部分。
> 上游仓库 URL：`<待补充 — 闭测期间私有>`（v1.0 GA 后公开）

---

## 0. 同步约束

**任何 IPC 字段、规则字段、disposition 行为变更，必须两个仓库同时改 SPEC + 协议版本号。**

由提交者手动协调。建议步骤：

1. 在 daemon 仓库改 `SPEC-002`（IPC 行为）/ `data-model.md`（audit.db schema）/ `PRD v2.0`
2. 在本仓库同步改 `docs/api/ipc-protocol.md` + `docs/specs/SPEC-008-ipc-client.md` + 相关 SPEC
3. 协议版本号 `protocol_version` 递增（不向后兼容）
4. 两个仓库的 PR 互相关联，同 review 同 merge

---

## 1. 上游 PRD

### PRD v2.0
- **路径（上游仓库内）**：`docs/requirements/sieve-prd-v2.0.md`
- **本仓库依赖章节**：
  - §1 产品定位（"daemon 不弹窗"约束的根源）
  - §5.4 处置矩阵（disposition 字段的语义）
  - §5.6 隐私字段（caller_pid / caller_exe 的可选性）
  - §9 硬约束（10 条全集，本仓库摘录到 PRD §9）
  - §10 不做清单
  - §11.2 不存原文承诺

---

## 2. 上游 ADR

### ADR-012：native-gui-app-phase1
- **决策**：Phase 1 GUI 用 SwiftUI native，独立 git 仓库 `sieve-gui-macos`
- **本仓库依赖**：技术栈锁定的根源；本仓库的 [ADR-001](../design/adr/ADR-001-swiftui-native-only-stack.md) 是这条决策在 GUI 仓库内的延伸表达

### ADR-013：ipc-protocol
- **决策**：IPC 走 Unix Domain Socket + JSON-RPC 2.0，协议版本 v1
- **本仓库依赖**：
  - 协议格式（JSON-RPC 2.0、无 batch、服务端可主动 notify）
  - socket 路径（`~/.sieve/ipc.sock`）
  - 权限要求（0600）
  - 协议版本号语义
- **本仓库实现端**：[`docs/api/ipc-protocol.md`](../api/ipc-protocol.md)、[`SPEC-008`](../specs/SPEC-008-ipc-client.md)

### ADR-014：dual-layer-defense
- **决策**：GuiPopup 类规则走 GUI；HookTerminal 类规则走 Claude Code Hook 终端
- **本仓库依赖**：知道哪些 disposition 是 GUI 渲染范围（`GuiPopup | AutoRedact | StatusBar`），哪些不是（`HookTerminal`）

### ADR-015：sieve-setup-tool
- **决策**：`sieve setup` CLI 子命令做自动配置
- **本仓库依赖**：
  - Onboarding step 2 / step 6 调用 `sieve setup`、`sieve doctor`
  - GUI 通过 `Process` spawn 终端运行，不参与配置逻辑

### ADR-016：disposition-matrix-2d
- **决策**：disposition 字段从一维扩展为二维（direction × severity）
- **本仓库依赖**：渲染逻辑根据 (direction, severity) 二元决定：
  - HIPS 主按钮位置
  - Toast 颜色与持续时间
  - 历史列表的图标

### ADR-021：tri-state-decision-and-graylist
- **决策**：三态决策（allow / deny / remember）+ critical_lock 三道防线
- **本仓库依赖（关键！）**：
  - **防线一**：GUI 不参与计算 `allow_remember`，无条件信任 daemon 字段
  - **防线三**：`allow_remember == false` 时**严禁**渲染 Remember checkbox（不允许灰显）
  - 灰名单字段 schema（fingerprint、context_hint、created_at）
- **违反这条 = 与 v1.5.4 P0 同级别安全漏洞**
- **本仓库实现端**：[`SPEC-002`](../specs/SPEC-002-hips-popup-window.md) §5.6 / [`CLAUDE.md`](../../CLAUDE.md) 硬约束 §1

---

## 3. 上游 SPEC

### SPEC-005：ipc-protocol（**双仓库唯一权威 IPC 协议规格**）
- **路径（上游仓库内）**：`docs/specs/SPEC-005-ipc-protocol.md`
- **覆盖**：所有 IPC 方法名、字段、枚举、错误码、握手、心跳、版本协商、协议升级流程、schema 一致性测试约定
- **当前 pinned commit**：`<待 GUI 代码 PR 时填入 SPEC-005 commit hash>`
- **本仓库依赖**：所有 IPC 字段定义都来自此文件；GUI 端不复刻 schema 表
- **本仓库实现端**：
  - [`docs/api/ipc-protocol.md`](../api/ipc-protocol.md) v2.0（GUI 实现注解，不再定义 schema）
  - [`SPEC-008-ipc-client.md`](../specs/SPEC-008-ipc-client.md)（GUI IPC 客户端实现规格）
  - `Sources/Services/IPC/`、`Sources/Models/HipsRequest*.swift` 等
- **变更协调**：任何 SPEC-005 改动必须先在 daemon 仓库 merge SPEC PR，再分别在两仓提代码 PR；本仓库 commit pin 字段必须更新

### SPEC-002：hips-popup-behavior
- **覆盖**：HIPS 弹窗的 IPC 行为契约（多 issue 合并字段、超时三段、merged_decision 格式、`default_on_timeout` fail-closed）
- **本仓库实现端**：[`SPEC-002-hips-popup-window.md`](../specs/SPEC-002-hips-popup-window.md)（GUI 渲染规格）+ [`api/ipc-protocol.md`](../api/ipc-protocol.md)（GUI 实现注解）

### SPEC-003：sieve-setup-tool
- **覆盖**：`sieve setup` / `sieve doctor` / `sieve uninstall` 行为
- **本仓库依赖章节**：
  - §4.1 doctor 5 项检查（Onboarding step 2 渲染）
  - §3 setup 输出格式（GUI spawn 终端后展示日志）
- **本仓库实现端**：[`SPEC-006-onboarding-flow.md`](../specs/SPEC-006-onboarding-flow.md) §3

---

## 4. 上游 data-model

### audit.db schema
- **路径（上游仓库内）**：`docs/design/data-model.md` §6
- **本仓库依赖**：
  - 表结构（`events` / `decisions` / `graylist`）
  - 字段类型与索引
  - `PRAGMA user_version` 升级语义
  - append-only 触发器（GUI 不能写入）
- **本仓库实现端**：[`SPEC-004-history-window.md`](../specs/SPEC-004-history-window.md) §3.1 + [`docs/design/data-model.md`](../design/data-model.md) §3

---

## 5. 上游 architecture

### Sieve 整体架构
- **路径（上游仓库内）**：`docs/design/architecture.md` §6
- **本仓库依赖**：daemon 在端口 `11453` 监听、IPC 在 `~/.sieve/ipc.sock` 暴露、GUI 在系统中的位置
- **本仓库实现端**：[`docs/design/architecture.md`](../design/architecture.md)（GUI 视角的架构）

---

## 6. 上游 CLI / 文件系统约定

GUI 不调用 daemon 的 HTTP 端口，但需要知道以下约定：

| 路径 | 谁写 | GUI 用途 |
|------|-----|---------|
| `~/.sieve/ipc.sock` | daemon（launchd 启动后） | GUI 连这个做 IPC |
| `~/.sieve/audit.db` | daemon | GUI 只读读历史 |
| `~/.sieve/sieve.toml` | 用户 + daemon reload | 设置 → daemon Tab 显示路径 |
| `~/.sieve/rules/user.toml` | 用户（`sieve rules edit`） | 设置 → 检测预设 Tab 显示路径 |
| `~/.sieve/decisions/` | daemon | GUI 通过 IPC 列出/删除（不直接读文件） |
| `~/.sieve/daemon.log` / `~/.sieve/daemon.err` | daemon | 诊断包打包源 |
| `~/.sieve/setup.log` | `sieve setup` | 诊断包打包源 |
| `~/.sieve/gui.log` | **本仓库 GUI** | 唯一 GUI 自己写的文件 |

GUI 必须 0700 / 0600 权限校验 `~/.sieve/`，不符合时引导修复（[`SPEC-006`](../specs/SPEC-006-onboarding-flow.md) §4.2）。

---

## 7. 协议版本兼容性

| protocol_version | daemon 起始版本 | GUI 起始版本 | 状态 |
|------------------|----------------|-------------|------|
| `v1` | daemon v0.x（v1.5 实现） | GUI v0.x | **Deprecated**（schema drift 严重，已弃用） |
| `v2` | daemon v0.7+（SPEC-005 v2.0 落地后） | GUI v1.0 | Active（双仓库统一 schema） |

未来递增策略：
- 字段新增（向后兼容） → 不递增 `protocol_version`，但更新 `ipc-protocol.md` 标注引入版本
- 字段语义变更 / 字段删除 → 递增 `protocol_version`，旧版本 GUI 进入 disconnected

---

## 8. 失联约束（再次强调）

GUI 失联 ≠ daemon 不工作。daemon 端 IPC 超时后按 `default_on_timeout` 处置（Critical = Block）。
**GUI 失联只意味着"用户失去了'允许'的能力"，安全侧没有放宽。**

GUI 的 disconnected UI 只承诺"显示数据可能过时" + "禁用所有写入操作"，不承诺继续做安全决策。
