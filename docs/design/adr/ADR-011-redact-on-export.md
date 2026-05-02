# ADR-011：诊断包导出走统一脱敏管线，默认不依赖用户阅读条款

> Status: Accepted
> Date: 2026-05-02
> Deciders: doskey
> Tags: security, infra

## Context

Sieve GUI 提供"导出诊断包"功能（PRD §5.3.6 / §8.3），将以下文件打包供用户发送给开发者排查问题：

- `~/.sieve/audit.db`（事件历史，含 evidence_meta）
- `~/.sieve/daemon.log` / `~/.sieve/daemon.err`（daemon 运行日志）
- `~/.sieve/setup.log`（sieve setup 安装日志）
- `~/.sieve/gui.log`（GUI 自身日志）

这些文件可能包含敏感信息：
- `audit.db` 的 `evidence_meta` 字段含命中事件的元数据（hash、前缀等，虽不是原文但仍可能泄露信息）
- `daemon.log` 可能含 IP 地址、caller_exe 完整路径、时间戳模式等
- `setup.log` 可能含 ANTHROPIC_BASE_URL、环境变量值

核心约束（CLAUDE.md 硬约束 7 / PRD §9 条 10）：
**"导出诊断包默认脱敏，不依赖用户阅读条款"**

这意味着：即使用户没有仔细阅读"这个包会包含什么"的说明，导出的文件也不会泄露敏感内容。

## Options Considered

### Option 1：原文直接打包，依赖用户判断（不可接受）
- 优点：零工作量
- 缺点：直接违反 PRD §9 条 10 和 CLAUDE.md 硬约束 7；用户（尤其是非技术用户）无法判断 daemon.log 中哪些行含敏感信息
- 估计成本：不可接受

### Option 2：DiagnosticPackager 统一脱敏管线 + 明文路径展示给用户自决（本方案）
- 优点：
  - 强制脱敏是默认路径，用户"不看条款也安全"
  - `DiagnosticPackager` 是唯一能读 evidence 字段的代码路径，集中审计
  - 明文告诉用户"导出文件已保存到桌面 Desktop/sieve-diagnostic-YYYYMMDD.zip，你可以在发送前用文本编辑器查看"——用户有最终的自决权
  - 各文件有独立的脱敏策略，审计清晰
- 缺点：脱敏逻辑需要维护，daemon.log 格式变化时 redact patterns 可能需要更新
- 估计成本：中等，一次性投入，维护成本低

### Option 3：每次导出前让用户勾选要包含的字段
- 优点：用户完全控制
- 缺点：
  - 依赖用户知道哪些字段是敏感的（大多数用户不知道）
  - UI 复杂度高（需要字段级勾选界面）
  - 与"不依赖用户阅读条款"的约束冲突
- 估计成本：高，且体验差

### Option 4：不提供诊断包功能，用户手动复制日志
- 优点：零风险
- 缺点：故障排查体验极差；PRD 明确要求此功能（§5.3.6）
- 估计成本：需求不满足

## Decision

选择 Option 2：**DiagnosticPackager 统一脱敏管线**，以下策略为默认：

**audit.db 转 NDJSON 时的脱敏规则**：

保留字段（无敏感）：
- `id`, `created_at`, `direction`, `severity`, `rule_id`, `disposition`, `user_choice`, `fingerprint`（短前缀，取前 8 位）

去除字段（脱敏）：
- `evidence_meta`（完整 JSON 去掉，替换为 `"<redacted>"`）
- `session_id`（去除）
- `caller_pid`（去除）
- `caller_exe`（只保留 basename，去掉完整路径）

```swift
// DiagnosticPackager.exportAuditDB(_ path: URL) -> URL
// 读取 audit.db，输出 NDJSON，每行一条 EventRow（按上述字段白名单）
```

**daemon.log / daemon.err 脱敏 patterns**：

```
redact_patterns = [
    // IP 地址（保留 127.0.0.1，其他替换）
    /\b(?!127\.0\.0\.1)\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/ → "[IP_REDACTED]"
    // HOME 路径（如 /Users/doskey/...）
    /\/Users\/[^\/\s]+/ → "/Users/[USER]"
    // ANTHROPIC_BASE_URL 值
    /ANTHROPIC_BASE_URL=\S+/ → "ANTHROPIC_BASE_URL=[REDACTED]"
    // API key 模式（sk-ant-... / sk-...）
    /sk-[a-zA-Z0-9_-]{10,}/ → "[API_KEY]"
    // 助记词（12/24 个小写英文单词连续出现）
    // (近似匹配，误伤率低)
]
```

**setup.log**：同上 patterns。

**gui.log**：gui.log 写入时已经遵守 data-model.md §4 的禁写规则（不含敏感字段），可直接打包，只做路径脱敏。

**明文路径展示**：导出完成后弹 `NSAlert` 或在 About 页面展示：
> 诊断包已保存到：~/Desktop/sieve-diagnostic-20260502.zip
> 发送前可用"归档实用工具"查看内容。所有敏感字段已脱敏处理。

**代码路径唯一性**：`DiagnosticPackager` 是整个 codebase 中唯一可以调用 `audit.db` 的 evidence 相关字段读取逻辑（`SELECT evidence_meta FROM events`）的地方。其他任何代码路径不得读取 `evidence_meta` 的完整值并写出到文件。

## Consequences

**正面影响**：
- 默认安全：用户无需理解哪些字段敏感，export 结果始终是脱敏版本
- 集中审计：所有敏感字段读取逻辑在 `DiagnosticPackager` 一处，code review 集中
- 明文路径让用户在发送前可以自己验证脱敏结果

**引入的新约束**：
- `DiagnosticPackager` 内的代码是高安全风险区域，任何变更需要专项 review
- 当 daemon.log 格式变化（新字段、新 pattern）时，`redact_patterns` 可能需要更新；需要在 daemon 升级日志里检查
- 脱敏后的 NDJSON 导出不含 `evidence_meta`，可能在某些复杂 bug 排查时减少调试信息——这是有意的权衡
- `caller_exe` 只保留 basename，如有同名 binary 的 ambiguity 在诊断时是可接受的损失

**后续需要做的事**：
- 实现 `DiagnosticPackager`（`Services/Diagnostics/` 目录）
- 实现 `RedactPipeline`（log 文件的 pattern 替换）
- 集成测试：构造含敏感 pattern 的 mock 日志，验证脱敏后不含任何 pattern 匹配
- 在 About Tab UI 标注"诊断包中的字段白名单"（透明度）

## References

- PRD §5.3.6（About 标签导出诊断包）、§8.3（隐私：导出脱敏规格）、§9 条 10
- CLAUDE.md 硬约束 7（导出诊断包默认脱敏）
- [`docs/design/architecture.md`](../architecture.md) §9（安全架构：DiagnosticPackager 说明）
- [`docs/design/data-model.md`](../data-model.md) §4（gui.log 禁写规则）
- 上游 [ADR-021（tri-state-decision-and-graylist）](../../external/upstream-references.md#adr-021tri-state-decision-and-graylist)（evidence 不存原文承诺，与本 ADR 呼应）
