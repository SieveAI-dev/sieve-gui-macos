# SPEC-005 v2 wire fixture — pin 自 daemon 仓权威源

> 本目录下全部 `*.json` 是 **daemon 仓 SPEC-005 §14.1 权威 wire fixture 的字节一致副本**，
> 由 `IPCSchemaV2FixtureTests` 经 `Bundle.module` 逐个消费、用对应 Swift DTO 解码验证，
> 建立防跨仓协议漂移的红线（见 daemon 仓 `tasks/lessons.md` 2026-06-11「preset default→standard
> 漂移只改一端、fixture 防漂移名存实亡」条）。

## Pin 信息

| 字段 | 值 |
|---|---|
| 上游 SPEC | SPEC-005 IPC 协议 v2.0（Status: Frozen，2026-05-02） |
| wire `protocol_version` | `v2` |
| fixture 来源仓 | `sieve`（daemon, Rust） |
| fixture 来源路径 | `crates/sieve-ipc/tests/fixtures/v2/` |
| **fixture 来源 commit** | daemon HEAD `8d68912` + 未提交工作区 D1-D7 漂移修正（11 个 fixture，待 daemon 提交后回填 commit 号） |
| daemon HEAD（复制时） | `8d68912`（2026-06-11） |
| 复制时间 | 2026-06-18（D1-D7 漂移修正后全量重新 `cp`，与 daemon 工作区逐字节一致） |

## 复制约束（不可破坏）

1. **字节一致**：这些文件必须逐字节等于 daemon 仓对应文件。daemon 侧 `schema_v2_fixtures.rs`
   的 `health_response_full_deserializes_and_roundtrips` 等测试保证 fixture == daemon 真实序列化输出
   （SPEC-005 §14.1 双向稳定）；本仓消费同一份 = 两侧无漂移空间。
2. **禁止"顺手修正"**：即使发现 fixture 里有看似过时的值（如 preset `mode: "default"`），
   **也不要在本仓改**——那会让副本偏离权威源、掩盖真实漂移。漂移必须在 daemon 仓修，再同步回来。
3. **同步流程**：daemon 仓 fixture 变更 → 重新 `cp` 全量覆盖本目录 → 更新本文件 commit 字段 →
   跑 `IPCSchemaV2FixtureTests` 确认绿。

## 跨仓漂移 D1-D7（2026-06-18 本次消费暴露 → 已修复并对齐）

daemon 侧已按 SPEC-005 修正全部 7 类漂移（工作区改动，待提交），本仓已同步：fixture 全量重新 `cp`
对齐 + GUI DTO 对齐 + `IPCSchemaV2FixtureTests` 断言从 `#expect(throws:)` 翻转为「解码成功 + 字段正确」。

| 漂移 | wire 修正（daemon） | GUI 侧动作 |
|---|---|---|
| **D1** sieve.hello | `preset "default"→"standard"`（SPEC §5.6） | 仅 fixture（`Preset` enum 已含 `.standard`） |
| **D2** sieve.set_preset | `mode "default"→"standard"` | 仅 fixture |
| **D3** sieve.preset_changed | 只发 `mode`，无 `preset`（SPEC §10.1） | `PresetChangedParams` 删 `preset` 字段；router 改用 `Preset(rawValue: mode)` |
| **D4** sieve.paused_changed | 补 `source`(required) | 仅 fixture（DTO 本就要 `source`） |
| **D5** sieve.notify_status_bar | `StatusBarNotify`：notify_id/created_at/kind/title/detail?/rule_id?/auto_dismiss_seconds（SPEC §10.1） | `EventNotifyParams` 整体重写对齐；ToastController / AppStateIPCAdapter 消费点适配（severity/direction 由 kind 派生） |
| **D6** sieve.purge_history | `purged_at` epoch ms 数字 → ISO8601 串（SPEC §11B） | 仅 fixture（DTO 本就当 ISO 串解） |
| **D7** sieve.evaluate | `would_recommendation` String → Recommendation 对象（SPEC §6.1.4） | `EvaluateResult.Match.wouldRecommendation: String? → Recommendation?` |

验证：`swiftc -typecheck` DTO + 测试文件 0 错；探针对 D1-D7 全部 fixture 实跑 `JSONDecoder().decode` = 21/21 pass。
