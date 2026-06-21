# 文档体系规范 v2.0

> 适用范围：本仓库（`sieve-gui-macos`）所有 Markdown 文档
> 上次更新：2026-05-02
> 上游来源：全局 `~/.claude/CLAUDE.md` DOCS-STANDARD v2.0

---

## 0. 原则

> 安全性 > 一致性 > 完整性 > 简洁性

- **一文件一职责**。一个 ADR 一个决策，一个 SPEC 一个模块。散落的小文件必须归目录；单文件不建目录。
- **ADR 只增不改**。决策变了写新 ADR，旧的标记为「被取代」。**禁止**在 ADR 文件里改写已发布的决策。
- **research/（外部事物调研） vs review/（本项目产出物评审）严格区分**。
- **CLAUDE.md 引用而非复制**，控制在 300 行以内。
- **文档正文中文，文件名全英文**。
- **版本化文档（PRD、architecture、api-reference、Spec）**第一行下面标注 `> Version: vX.Y — YYYY-MM-DD`。

---

## 1. 目录结构

```
docs/
├── DOCS-STANDARD.md          ← 本文件
├── glossary.md               ← 术语表
├── requirements/             ← PRD、用户故事
├── design/
│   ├── architecture.md       ← 系统架构
│   ├── data-model.md         ← 数据模型
│   └── adr/
│       ├── INDEX.md          ← ADR 索引
│       └── ADR-NNN-*.md      ← 单个决策
├── specs/
│   ├── INDEX.md              ← SPEC 索引
│   └── SPEC-NNN-*.md         ← 单个功能技术规格
├── api/
│   └── ipc-protocol.md       ← API 参考
├── guides/
│   ├── development.md
│   └── deployment.md
├── research/                 ← 对外部事物的调研（竞品、技术）
├── review/                   ← 对本项目产出物的评审
├── external/                 ← 第三方参考资料 / 上游仓库引用
└── review/_archive/          ← 历史 review 归档（超过 1 个月或被取代）
tasks/
├── PROGRESS.md               ← 单一进度真实源（任务前先看，完成后必更新）
├── roadmap.md                ← 长期路线图（可选）
├── lessons.md                ← 经验沉淀
└── _archive/                 ← 过期 todo / status 快照 / 临时报告归档
```

**`PROGRESS.md` 必含五段**：当前阶段一句话 / ✅ 已完成（按时间倒序）/ 🚧 进行中（≤3 项）/ ⏭ 下一步（按 P0/P1/P2 优先级，可勾选）/ 🚫 阻塞或等决策。任何时候打开应能在 30 秒内回答"现在做什么、做到哪、下一步是什么"。临时分析产物用 `_` 前缀（如 `_gap-*.md`），并入 PROGRESS 后立即删除。

**禁止建立的目录**：`docs/notes/`、`docs/temp/`、`docs/wip/`、`docs/misc/`。所有内容必须找到合适的归属目录。

---

## 2. 命名规则

| 类型 | 模式 | 示例 |
|------|-----|------|
| ADR | `ADR-NNN-描述-用-连字符.md` | `ADR-001-swiftui-native-only-stack.md` |
| SPEC | `SPEC-NNN-功能名.md` | `SPEC-002-hips-popup-window.md` |
| Review | `YYYY-MM-DD-来源-类型.md` | `2026-05-15-ipc-spec-internal-review.md` |
| Research | `YYYY-MM-DD-主题.md` 或 `主题名.md` | `swiftui-window-scenes-survey.md` |

ADR / SPEC 编号规则：
- 三位编号，**递增不跳号**（已废弃的也保留占位，文件标记 `Status: superseded by ADR-NNN`）
- 编号一旦发布就不改

---

## 3. ADR 模板

```markdown
# ADR-NNN：{决策一句话}

> Status: Accepted | Proposed | Superseded by ADR-MMM | Deprecated
> Date: YYYY-MM-DD
> Deciders: SieveAI
> Tags: ipc, ui, security, build, ...

## Context

为什么要做这个决策？背景、约束、问题。

## Options Considered

### Option 1：{方案 A}
- 优点
- 缺点
- 估计成本

### Option 2：{方案 B}
- ...

### Option 3：{方案 C}
- ...

## Decision

选了 Option N。**一句话写清楚选了什么**。

## Consequences

- 正面影响
- 负面影响 / 引入的新约束
- 后续需要做的事

## References

- 相关 PRD 章节链接
- 相关 SPEC 链接
- 上游 ADR / 外部资料链接
```

---

## 4. SPEC 模板

```markdown
# SPEC-NNN：{模块名}

> Version: vX.Y — YYYY-MM-DD
> Status: Draft | Stable | Frozen
> Owner: SieveAI
> 关联 ADR：ADR-NNN, ADR-MMM
> 关联 PRD 章节：§5.X

## 0. 摘要

一段话写清楚这个模块是什么、解决什么问题、和谁交互。

## 1. 范围与非目标

- **范围**：本 SPEC 覆盖什么
- **非目标**：明确不做的事（防止 scope creep）

## 2. 用户路径 / 场景

按场景列出使用流程。每个场景一段话 + 状态机/序列图。

## 3. 状态机

```
状态名 ─event→ 下一状态
```

## 4. UI 规格

控件清单、布局约束、交互细节、动效、可访问性。

## 5. 数据契约

输入字段、输出字段、本地状态字段。引用 `docs/api/ipc-protocol.md` 而不是重复。

## 6. 错误与降级

- 失败模式表（条件 → 行为）
- 降级路径

## 7. 性能与硬约束

可量化指标 + 不可放宽的约束。

## 8. 测试要求

必须覆盖的关键测试用例。

## 9. 未决事项（OQ）

| 编号 | 问题 | 当前选项 | 截止决策 |
|------|------|---------|---------|

## 10. 变更记录

| 版本 | 日期 | 作者 | 变更 |
```

---

## 5. 文档生命周期

```
       ┌─────────┐    review     ┌─────────┐    sign-off  ┌────────┐
 Draft │  写初稿  │ ───────────→  │  Review  │ ───────────→ │ Stable │
       └─────────┘   团队评审    └─────────┘  收所有意见   └────┬───┘
                                                                │
                              ┌─────────────┐    deprecation    │
                              │  Deprecated │ ←─────────────────┤
                              └─────────────┘                   │
                              ┌─────────────┐    redesign       │
                              │ Superseded  │ ←─────────────────┘
                              └─────────────┘
```

- **Draft**：写作中，可随意改
- **Review**：发起评审，禁止结构性改动（只接受评审反馈式修改）
- **Stable**：通过评审，正式生效；后续修改递增 minor 版本（v1.0 → v1.1）
- **Frozen**（仅 SPEC）：发布版本对应的快照，禁止任何修改；下一版本另开文件
- **Deprecated**：不再维护，但内容保留供历史参考
- **Superseded**：被新文档取代，文件保留，开头标注 `> Superseded by ADR-MMM`

---

## 6. 上下游文档同步规则

变更触发表（与全局 CLAUDE.md 一致）：

| 场景 | 需更新的文档 | 优先级 |
|------|-------------|-------|
| 新增功能 | PRD + 设计文档 + README + CHANGELOG | P0 |
| 修改 IPC / 架构变更 | 对应 SPEC + ADR + ipc-protocol.md + CHANGELOG | P0 |
| Bug 修复（涉及逻辑） / 配置变更 | CHANGELOG + 相关文档 | P1 |
| 依赖升级 | CHANGELOG | P2 |

无需文档化的变更：纯格式化、注释优化（不涉及逻辑）、测试补充（无功能变更）。

**与上游 daemon 仓库的同步**：任何 IPC 字段或行为变更必须**两个仓库同时改 SPEC + 协议版本号**，由提交者手动协调（[`docs/external/upstream-references.md`](external/upstream-references.md)）。

---

## 7. 链接规范

- 仓库内链接用相对路径：`[architecture](../design/architecture.md)`
- 跨章节锚点用 GitHub 风格 slug：`[§5.2](#52-状态机)`
- 上游 daemon 仓库的引用必须经过 `docs/external/upstream-references.md` 中转，**禁止**正文里硬编码 GitHub URL

---

## 8. 写作风格

- **结论先行**：每个章节第一段说"是什么 / 为什么"，不要慢热
- **最少充分**：写够支撑决策的最少信息；冗余是负担
- **图优先**：能画图就别只写文字（ASCII art / Mermaid / Markdown 表格都行）
- **避免**：「我们」「让我们」「显而易见」「众所周知」「请注意」
- **保留专有名词英文**：rule_id、Permit2、EIP-712、SSE、daemon、IPC、preset 等

---

## 9. 审核检查表（PR Reviewer 用）

提交涉及文档的 PR 时，reviewer 检查：

- [ ] 命名符合 §2
- [ ] 版本化文档带 `> Version:` 标注
- [ ] ADR / SPEC 用了对应模板（§3 / §4）
- [ ] 没有把上游 daemon 文档复制进本仓库（应通过 external/ 引用）
- [ ] 修改了 IPC 相关文档时，`ipc-protocol.md` 与 `SPEC-008-ipc-client.md` 同步更新
- [ ] 链接路径都是相对路径，没有 hardcode GitHub URL
- [ ] CHANGELOG（首次发布前用 `tasks/PROGRESS.md` 代替）有同步条目
