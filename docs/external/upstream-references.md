# 上游引用 — Sieve daemon 仓库

> 本仓库（`sieve-gui-macos`）严格依赖上游 Rust daemon 仓库（`sieve`）的若干契约。
> 上游文档**不复制**到本仓库；本文件只列出依赖项 + 说明依赖的是哪部分。
> 上游仓库 URL：`https://github.com/SieveAI-dev/sieve`

---

## 0. 同步约束

**任何 IPC 字段、规则字段、disposition 行为变更，必须两个仓库同时改 SPEC + 协议版本号。**

由提交者手动协调。建议步骤：

1. 在 daemon 仓库改 `SPEC-005`（IPC 协议权威源）/ `data-model.md`（audit.db schema）/ `PRD v2.0`
2. 在本仓库同步改 `docs/api/ipc-protocol.md` + `docs/specs/SPEC-008-ipc-client.md` + 相关 SPEC
3. 协议版本号 `protocol_version` 递增（不向后兼容）
4. 两个仓库的 PR 互相关联，同 review 同 merge

---

## 1. 上游 PRD

### PRD v2.0
- **路径（上游仓库内）**：`docs/prd/sieve-prd-v2.0.md`
- **本仓库依赖章节**：
  - §1 产品定位（"daemon 不弹窗"约束的根源）
  - §5.4 处置矩阵（disposition 字段的语义）
  - §5.6 隐私字段（caller_pid / caller_exe 的可选性）
  - §9 硬约束（10 条全集，本仓库摘录到 PRD §9）
  - §10 不做清单
  - §11.2 不存原文承诺

---

## 2. 上游架构决策（功能契约）

> 下列为本仓库依赖的上游 daemon 架构决策，按功能契约自包含描述；权威 wire / schema 以上游公开 SPEC-005 为准。

### native-gui-app（Phase 1）
- **决策**：Phase 1 GUI 用 SwiftUI native，独立 git 仓库 `sieve-gui-macos`
- **本仓库依赖**：技术栈锁定的根源；本仓库 SwiftUI native-only 技术栈是这条决策在 GUI 仓库内的延伸表达

### ipc-protocol
- **决策**：IPC 走 Unix Domain Socket + JSON-RPC 2.0，协议版本 v1（后续升级至 v2，权威定义见上游 SPEC-005）
- **本仓库依赖**：
  - 协议格式（JSON-RPC 2.0、无 batch、服务端可主动 notify）
  - socket 路径（`~/.sieve/ipc.sock`）
  - 权限要求（0600）
  - 协议版本号语义
- **本仓库实现端**：[`docs/api/ipc-protocol.md`](../api/ipc-protocol.md)、[`SPEC-008`](../specs/SPEC-008-ipc-client.md)

### dual-layer-defense
- **决策**：GuiPopup 类规则走 GUI；HookTerminal 类规则走 Claude Code Hook 终端
- **本仓库依赖**：知道哪些 disposition 是 GUI 渲染范围（`GuiPopup | AutoRedact | StatusBar`），哪些不是（`HookTerminal`）

### sieve-setup-tool
- **决策**：`sieve setup` CLI 子命令做自动配置
- **本仓库依赖**：
  - Onboarding step 2 / step 6 调用 `sieve setup`、`sieve doctor`
  - GUI 通过 `Process` spawn 终端运行，不参与配置逻辑

### disposition-matrix-2d
- **决策**：disposition 字段从一维扩展为二维（direction × severity）
- **本仓库依赖**：渲染逻辑根据 (direction, severity) 二元决定：
  - HIPS 主按钮位置
  - Toast 颜色与持续时间
  - 历史列表的图标

### tri-state-decision-and-graylist
- **决策**：三态决策（allow / deny / remember）+ critical_lock 三道防线
- **本仓库依赖（关键！）**：
  - **防线一**：GUI 不参与计算 `allow_remember`，无条件信任 daemon 字段
  - **防线三**：`allow_remember == false` 时**严禁**渲染 Remember checkbox（不允许灰显）
  - 灰名单字段 schema（fingerprint、context_hint、created_at）
- **违反这条 = 与 v1.5.4 P0 同级别安全漏洞**
- **本仓库实现端**：[`SPEC-002`](../specs/SPEC-002-hips-popup-window.md) §5.6 / [`CLAUDE.md`](../../CLAUDE.md) 硬约束 §1

### port-based-listener-routing
- **决策**：daemon `Config.upstream_url` + `Config.port` 升级为 `Config.upstreams: Vec<UpstreamListener>`，每个 listener 显式声明 `provider_id` + `protocol`
- **本仓库依赖**：
  - `sieve.health` 响应新增顶层 `listeners: ListenerSnapshot[]` 字段（每项 `addr / port / provider_id / protocol`）
  - 旧 `listen: ListenSnapshot` 字段保留为 `listeners[0]` 别名（deprecated since v2.x），仅向后兼容
  - 协议版本号**不 bump**（v2 内向后兼容扩展，client 用 `decodeIfPresent ?? []` 兜底旧 daemon）
  - GUI doctor / Settings → Daemon Tab 应优先消费 `listeners[]`，空时回落到 `listen` 单值展示
- **本仓库实现端**：[`Sources/Models/IPCResponses.swift`](../../Sources/Models/IPCResponses.swift) `HealthResultDTO.effectiveListeners` / [`Tests/SieveGUITests/HealthResultDTOTests.swift`](../../Tests/SieveGUITests/HealthResultDTOTests.swift)

### network-jail-enforcement
- **决策（v3.x 范畴）**：按 LLM endpoint host 切片做 daemon 进程 network jail
- **本仓库依赖**：当前无（GUI 决策路径不联网，与 jail 规则无交集）
- **未来需关注**：v3.x 起 doctor 输出可能新增 jail 状态字段，到时同步 health DTO

### ipc-protocol-neutralization
- **决策**：SPEC-005 协议术语中性化（"GUI 端" → "client 端"，"弹窗" → "decision request / decision event"），sieve-ipc crate 内部模块化为 `protocol/` + `server/` + `client/`，新增 headless decision path（`sieve decisions watch / show / resolve` CLI 子命令）
- **本仓库依赖**：
  - **wire 字段名 + method 名全部不变**（`sieve.request_decision` / `sieve.request_decision_canceled` / `gui_popup` disposition 枚举值均保留向后兼容）—— GUI 代码无需迁移
  - 协议版本号**不 bump**（仍 v2）
  - SPEC-005 §3.3 加 admonition：「以下行为属于 sieve-gui-macos 仓的 GUI 实现细节，不是 daemon IPC 协议契约」—— 我方文档保持「GUI 实现注解」定位即可
  - daemon 协议层不再视 GUI 为特权 client；GUI 与 CLI / TUI 等 headless client 在协议层地位平等
- **本仓库实现端**：仅文档同步（[`docs/api/ipc-protocol.md`](../api/ipc-protocol.md) 协议变更日志）；代码侧无改动

---

## 3. 上游 SPEC

### SPEC-005：ipc-protocol（**双仓库唯一权威 IPC 协议规格**）
- **路径（上游仓库内）**：`docs/specs/SPEC-005-ipc-protocol.md`
- **覆盖**：所有 IPC 方法名、字段、枚举、错误码、握手、心跳、版本协商、协议升级流程、schema 一致性测试约定
- **SPEC-005 最后改动 commit**：`7108a45`（listeners[] 数组扩展，向后兼容、未 bump `protocol_version`）。截至 daemon HEAD `8d68912`，SPEC-005 文档最后改动仍为 `7108a45`。
- **fixture 副本来源（SPEC §14.2）**：`Tests/SieveGUITests/Fixtures/v2/` 现为 daemon 全部 **19 个 method 目录 / 81 个权威 fixture** 的字节一致副本（2026-06-18 从 `sieve.health` 一个目录扩到全量），pin 自 daemon fixtures/v2 目录最近 commit **`ae20fd3`**（daemon HEAD `8d68912`，2026-06-11）。`IPCSchemaV2FixtureTests` 逐个用对应 Swift DTO 解码校验跨仓一致；pin 细节见 `Tests/SieveGUITests/Fixtures/v2/_PIN.md`。
- **✅ 2026-06-18 D1-D7 跨仓漂移已修复并对齐**（daemon 按 SPEC-005 修正 wire，GUI 同步 DTO + fixture，`IPCSchemaV2FixtureTests` 断言已从 `#expect(throws:)` 翻转为「解码成功 + 字段正确」）：
  1. **D1 hello.preset**：daemon `"default"→"standard"`（SPEC §5.6）；GUI 仅改 fixture（`Preset` enum 已含 `.standard`）。
  2. **D3 preset_changed**：daemon 只发 `mode`（SPEC §10.1，无 `preset`）；GUI `PresetChangedParams` 删 `preset` 字段，router 改用 `Preset(rawValue: mode)`。
  3. **D4 paused_changed**：daemon 补 `source`(required)；GUI DTO 本就要 `source`，仅补 fixture。
  4. **D5 notify_status_bar**：daemon 发 `StatusBarNotify`（notify_id/created_at/kind/title/detail?/rule_id?/auto_dismiss_seconds，SPEC §10.1）；GUI `EventNotifyParams` 整体重写对齐，ToastController/AppStateIPCAdapter 消费点适配。
  5. **D6 purge_history.purged_at**：daemon epoch ms → ISO8601 串（SPEC §11B）；GUI DTO 本就当 ISO 串解，仅改 fixture。
  6. **D2 set_preset.request.minimal mode**：`"default"→"standard"`（与 D1 同源）；**D7 evaluate.would_recommendation**：daemon 对象（SPEC §6.1.4），GUI `Match.wouldRecommendation: String? → Recommendation?`。
- **GUI 端缺 DTO 的 method（不在本轮擅自新增，待协商）**：`reload_user_rules`（无 handler/DTO）、`remove_graylist` / `set_preset_overrides` 的 result（fire-and-forget 不解码）。
- **复核命令**（在 daemon 仓库执行）：`git log --oneline -- docs/specs/SPEC-005-ipc-protocol.md | head -1`
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
| `v2.x`（向后兼容扩展） | daemon v0.8+（port-based listener routing + 协议术语中性化落地后） | GUI v1.0+ | Active（health 新增 `listeners[]`、协议术语中性化；不 bump 主版本号） |

未来递增策略：
- 字段新增（向后兼容） → 不递增 `protocol_version`，但更新 `ipc-protocol.md` 标注引入版本
- 字段语义变更 / 字段删除 → 递增 `protocol_version`，旧版本 GUI 进入 disconnected

---

## 8. 失联约束（再次强调）

GUI 失联 ≠ daemon 不工作。daemon 端 IPC 超时后按 `default_on_timeout` 处置（Critical = Block）。
**GUI 失联只意味着"用户失去了'允许'的能力"，安全侧没有放宽。**

GUI 的 disconnected UI 只承诺"显示数据可能过时" + "禁用所有写入操作"，不承诺继续做安全决策。
