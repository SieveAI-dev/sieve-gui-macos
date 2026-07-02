# SPEC-005 v2 wire fixture — pin 自 daemon 仓权威源

> 本目录下全部 `*.json` 是 **daemon 仓 SPEC-005 §14.1 权威 wire fixture 的字节一致副本**，
> 由 `IPCSchemaV2FixtureTests` 经 `Bundle.module` 逐个消费、用对应 Swift DTO 解码验证，
> 建立防跨仓协议漂移的红线。

## Pin 信息

| 字段 | 值 |
|---|---|
| 上游 SPEC | SPEC-005 IPC 协议 v2.0（Status: Frozen） |
| wire `protocol_version` | `v2` |
| fixture 来源仓 | `sieve`（daemon, Rust） |
| fixture 来源路径 | `crates/sieve-ipc/tests/fixtures/v2/` |

## 复制约束（不可破坏）

1. **字节一致**：这些文件必须逐字节等于 daemon 仓对应文件。daemon 侧
   `schema_v2_fixtures.rs` 的 `health_response_full_deserializes_and_roundtrips` 等测试保证
   fixture == daemon 真实序列化输出（SPEC-005 §14.1 双向稳定）；本仓消费同一份 = 两侧无漂移空间。
2. **禁止"顺手修正"**：即使发现 fixture 里有看似过时的值（如 preset `mode: "default"`），
   **也不要在本仓改**——那会让副本偏离权威源、掩盖真实漂移。漂移必须在 daemon 仓修，再同步回来。
3. **同步流程**：daemon 仓 fixture 变更 → 重新 `cp` 全量覆盖本目录 →
   跑 `IPCSchemaV2FixtureTests` 确认绿。

## wire 字段对照（SPEC-005 v2 关键约束）

下表记录几处易混淆字段的权威 wire 形态与 GUI DTO 的对齐方式，供消费侧核对：

| 消息 | wire 约束（SPEC） | GUI 侧形态 |
|---|---|---|
| sieve.hello | `preset` 取值含 `"standard"`（SPEC §5.6） | `Preset` enum 含 `.standard` |
| sieve.set_preset | `mode` 取值含 `"standard"` | 与 `Preset` 对齐 |
| sieve.preset_changed | 只发 `mode`，无 `preset`（SPEC §10.1） | `PresetChangedParams` 无 `preset` 字段；router 用 `Preset(rawValue: mode)` |
| sieve.paused_changed | `source` 为 required | `source` 为必填字段 |
| sieve.notify_status_bar | `StatusBarNotify`：notify_id/created_at/kind/title/detail?/rule_id?/auto_dismiss_seconds（SPEC §10.1） | `EventNotifyParams` 对齐；severity/direction 由 kind 派生 |
| sieve.purge_history | `purged_at` 为 ISO8601 串（SPEC §11B） | DTO 按 ISO 串解 |
| sieve.evaluate | `would_recommendation` 为 Recommendation 对象（SPEC §6.1.4） | `EvaluateResult.Match.wouldRecommendation: Recommendation?` |
| sieve.request_decision | params 含 optional `provider_id`（CLI spec 新增） | GUI `HipsRequestDecoder` 宽松解码忽略未知字段，不消费语义 |
| sieve.list_pending | CLI headless 专用（daemon CLI spec 新增） | GUI 不实现 handler，仅维护 fixture 副本护跨仓一致性 |
| sieve.resolve_decision | CLI headless 专用（daemon CLI spec 新增）；Critical 由 daemon severity 门禁拦截 | GUI 不实现 handler，仅维护 fixture 副本；GUI 侧对应防线 = Critical allow TouchID 门（P0-1） |

验证：DTO + 测试文件 `swiftc -typecheck` 0 错；探针对上述全部 fixture 实跑 `JSONDecoder().decode` 全部通过。
