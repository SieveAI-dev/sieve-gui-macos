import Foundation
import Testing

@testable import SieveGUICore

/// SPEC-005 §14.2：消费 daemon 权威 fixture 副本（`Tests/SieveGUITests/Fixtures/v2/`），
/// 而非内联手写 JSON——保证 GUI 解码与 daemon 序列化输出对齐，杜绝跨仓 schema 漂移。
///
/// 本套件覆盖 daemon 仓 `crates/sieve-ipc/tests/fixtures/v2/` 全部 19 个 method 目录、
/// 81 个权威 fixture（pin 见 `Fixtures/v2/_PIN.md` + `docs/external/upstream-references.md`）。
/// daemon 侧 `schema_v2_fixtures.rs` 的双向稳定测试保证这些 fixture 等于 daemon 真实 wire 输出；
/// 本测试保证 GUI 端对应 DTO 能消费同一份权威 fixture。两侧共用同一 JSON = 无漂移空间。
///
/// ## 红线机制（关键）
///
/// 本套件**实证暴露了 6 类跨仓漂移**（2026-06-18，用 GUI 真实 DTO 逐个解码副本）。对每个
/// 当前会解码失败的 method，下方以 `#expect(throws:)` **钉死破裂现状**——这不是「测试通过 =
/// 协议健康」，而是「测试通过 = 漂移现状未变」。daemon 仓修复对应漂移后，必须把这些断言从
/// 「应抛错」翻转为「应解码成功 + 字段正确」，CI 才会强制两仓重新对齐。漂移清单见 `_PIN.md`。
///
/// 与 `HealthResultDTOTests`（内联 JSON 覆盖解码逻辑分支）互补：本测试专测「与 daemon
/// 权威产物的一致性」，前者测「解码逻辑的完整性」。
@Suite("SPEC-005 §14.2 daemon fixture 副本一致性")
struct IPCSchemaV2FixtureTests {

    // MARK: - fixture 加载辅助

    /// 读取某 method 目录下的 fixture 文件原始 Data。
    private static func loadFixture(_ method: String, _ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/v2/\(method)"
            ),
            "fixture \(method)/\(name).json 缺失——应从 daemon 仓 crates/sieve-ipc/tests/fixtures/v2/ 拷贝"
        )
        return try Data(contentsOf: url)
    }

    /// 剥 JSON-RPC envelope，提取指定顶层字段（`result` / `params`）的原始 Data。
    private static func extract(_ method: String, _ name: String, field: String) throws -> Data {
        let data = try loadFixture(method, name)
        let obj = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "fixture \(method)/\(name).json 不是 JSON object"
        )
        let sub = try #require(obj[field], "fixture \(method)/\(name).json 缺 \(field) 字段")
        return try JSONSerialization.data(withJSONObject: sub)
    }

    private static func decoder() -> JSONDecoder { JSONDecoder() }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - 健康的 method（解码成功 + enum 字段值正确）
    // ════════════════════════════════════════════════════════════════════════

    // ── sieve.health（已有 listeners[] 深度断言）──────────────────────────────

    @Test("sieve.health response.full：listeners[] 完整 + enum 值正确")
    func health_full() throws {
        let dto = try Self.decoder().decode(
            HealthResultDTO.self, from: Self.extract("sieve.health", "response.full", field: "result"))
        #expect(dto.protocolVersion == "v2")
        #expect(dto.preset.mode == .custom)
        #expect(dto.listeners.count == 2)
        #expect(dto.listeners[0].providerId == "anthropic")
        #expect(dto.listeners[0].protocol == "anthropic")
        #expect(dto.listeners[1].port == 11454)
        #expect(dto.listeners[1].providerId == "deepseek")
        #expect(dto.listeners[1].protocol == "auto")
        #expect(dto.effectiveListeners.count == 2)
        #expect(dto.listen.port == 11453)
        #expect(dto.paused == true)
    }

    @Test("sieve.health response.minimal：省略 listeners → effectiveListeners 回落 listen，mode=standard")
    func health_minimal() throws {
        let dto = try Self.decoder().decode(
            HealthResultDTO.self, from: Self.extract("sieve.health", "response.minimal", field: "result"))
        #expect(dto.preset.mode == .standard)   // ✅ health 已是 v2 标准值（ae20fd3 已修）
        #expect(dto.listeners.isEmpty)
        #expect(dto.effectiveListeners.count == 1)
        #expect(dto.effectiveListeners[0].port == 11453)
        #expect(dto.paused == false)
    }

    @Test("sieve.health response.null_optional：listeners 显式空数组 + 可选字段 null")
    func health_nullOptional() throws {
        let dto = try Self.decoder().decode(
            HealthResultDTO.self, from: Self.extract("sieve.health", "response.null_optional", field: "result"))
        #expect(dto.preset.mode == .standard)
        #expect(dto.listeners.isEmpty)
        #expect(dto.pausedUntil == nil)
        #expect(dto.rules.lastReload == nil)
    }

    // ── sieve.set_paused ──────────────────────────────────────────────────────

    @Test("sieve.set_paused response.full：paused=true + paused_until 解析")
    func setPaused_full() throws {
        let dto = try Self.decoder().decode(
            SetPausedResult.self, from: Self.extract("sieve.set_paused", "response.full", field: "result"))
        #expect(dto.paused == true)
        #expect(dto.pausedUntil != nil)
        #expect(dto.appliesTo.count == 3)
    }

    @Test("sieve.set_paused response.minimal：paused=false + applies_to=[]")
    func setPaused_minimal() throws {
        let dto = try Self.decoder().decode(
            SetPausedResult.self, from: Self.extract("sieve.set_paused", "response.minimal", field: "result"))
        #expect(dto.paused == false)
        #expect(dto.appliesTo.isEmpty)
    }

    @Test("sieve.set_paused response.null_optional：paused_until=null → nil")
    func setPaused_nullOptional() throws {
        let dto = try Self.decoder().decode(
            SetPausedResult.self, from: Self.extract("sieve.set_paused", "response.null_optional", field: "result"))
        #expect(dto.paused == false)
        #expect(dto.pausedUntil == nil)
    }

    // ── sieve.reload_config ───────────────────────────────────────────────────

    @Test("sieve.reload_config response.full：计数 + 无错误")
    func reloadConfig_full() throws {
        let dto = try Self.decoder().decode(
            ReloadConfigResult.self, from: Self.extract("sieve.reload_config", "response.full", field: "result"))
        #expect(dto.systemRulesCount == 15)
        #expect(dto.userRulesCount == 3)
        #expect(dto.userRulesErrors.isEmpty)
        #expect(dto.reloadedAt != nil)
    }

    @Test("sieve.reload_config response.minimal：默认计数")
    func reloadConfig_minimal() throws {
        let dto = try Self.decoder().decode(
            ReloadConfigResult.self, from: Self.extract("sieve.reload_config", "response.minimal", field: "result"))
        #expect(dto.systemRulesCount == 12)
        #expect(dto.userRulesCount == 0)
    }

    @Test("sieve.reload_config response.null_optional：user_rules_errors 非空")
    func reloadConfig_nullOptional() throws {
        let dto = try Self.decoder().decode(
            ReloadConfigResult.self, from: Self.extract("sieve.reload_config", "response.null_optional", field: "result"))
        #expect(dto.userRulesErrors.count == 1)
    }

    // ── sieve.list_rules（enum 字段 severity/direction/disposition 全覆盖）───────

    @Test("sieve.list_rules response.full：3 条规则 + enum 字段值正确")
    func listRules_full() throws {
        let dto = try Self.decoder().decode(
            ListRulesResult.self, from: Self.extract("sieve.list_rules", "response.full", field: "result"))
        #expect(dto.rules.count == 3)
        // IN-CR-01：critical / inbound / gui_popup / block / system
        let r0 = dto.rules[0]
        #expect(r0.ruleId == "IN-CR-01")
        #expect(r0.severity == .critical)
        #expect(r0.direction == .inbound)
        #expect(r0.disposition == .guiPopup)
        #expect(r0.defaultOnTimeout == .block)
        #expect(r0.criticalLock == true)
        #expect(r0.ruleKind == .system)
        // OUT-01：high / outbound / auto_redact / null default_on_timeout
        let r1 = dto.rules[1]
        #expect(r1.severity == .high)
        #expect(r1.direction == .outbound)
        #expect(r1.disposition == .autoRedact)
        #expect(r1.defaultOnTimeout == nil)
        // user rule：medium / status_bar / user
        let r2 = dto.rules[2]
        #expect(r2.severity == .medium)
        #expect(r2.disposition == .statusBar)
        #expect(r2.ruleKind == .user)
    }

    @Test("sieve.list_rules response.minimal：空数组")
    func listRules_minimal() throws {
        let dto = try Self.decoder().decode(
            ListRulesResult.self, from: Self.extract("sieve.list_rules", "response.minimal", field: "result"))
        #expect(dto.rules.isEmpty)
    }

    @Test("sieve.list_rules response.null_optional：severity=low + description=null")
    func listRules_nullOptional() throws {
        let dto = try Self.decoder().decode(
            ListRulesResult.self, from: Self.extract("sieve.list_rules", "response.null_optional", field: "result"))
        #expect(dto.rules.count == 1)
        #expect(dto.rules[0].severity == .low)
        #expect(dto.rules[0].description == nil)
    }

    // ── sieve.list_graylist ───────────────────────────────────────────────────

    @Test("sieve.list_graylist response.full：1 条 entry + 字段正确")
    func listGraylist_full() throws {
        let dto = try Self.decoder().decode(
            GraylistResponse.self, from: Self.extract("sieve.list_graylist", "response.full", field: "result"))
        #expect(dto.entries.count == 1)
        let e = dto.entries[0]
        #expect(e.ruleId == "IN-GEN-04")
        #expect(e.ruleKind == "system")
        #expect(e.addedBy == "user")
        #expect(e.contextHint != nil)
        #expect(e.matchCountSince == 3)
    }

    @Test("sieve.list_graylist response.minimal：空数组")
    func listGraylist_minimal() throws {
        let dto = try Self.decoder().decode(
            GraylistResponse.self, from: Self.extract("sieve.list_graylist", "response.minimal", field: "result"))
        #expect(dto.entries.isEmpty)
    }

    @Test("sieve.list_graylist response.null_optional：context_hint=null → nil")
    func listGraylist_nullOptional() throws {
        let dto = try Self.decoder().decode(
            GraylistResponse.self, from: Self.extract("sieve.list_graylist", "response.null_optional", field: "result"))
        #expect(dto.entries.count == 1)
        #expect(dto.entries[0].contextHint == nil)
        #expect(dto.entries[0].ruleKind == "user")
    }

    // ── sieve.evaluate（minimal/null_optional 健康；full 漂移见红线段）──────────

    @Test("sieve.evaluate response.minimal：空 matches")
    func evaluate_minimal() throws {
        let dto = try Self.decoder().decode(
            EvaluateResult.self, from: Self.extract("sieve.evaluate", "response.minimal", field: "result"))
        #expect(dto.matches.isEmpty)
    }

    @Test("sieve.evaluate response.null_optional：1 match + severity=medium + would_recommendation=null")
    func evaluate_nullOptional() throws {
        let dto = try Self.decoder().decode(
            EvaluateResult.self, from: Self.extract("sieve.evaluate", "response.null_optional", field: "result"))
        #expect(dto.matches.count == 1)
        #expect(dto.matches[0].ruleId == "IN-GEN-04")
        #expect(dto.matches[0].severity == .medium)
        #expect(dto.matches[0].disposition == "status_bar")
        #expect(dto.matches[0].wouldDecision == "allow")
        #expect(dto.matches[0].wouldRecommendation == nil)
    }

    // ── decision_response（GUI→daemon 回包，用 probe DTO 验证 enum 值）──────────

    @Test("decision_response response.full：decision=allow + ui_phase=blue")
    func decisionResponse_full() throws {
        let dto = try Self.decoder().decode(
            DecisionResponseProbe.self, from: Self.extract("decision_response", "response.full", field: "result"))
        #expect(dto.decision == .allow)
        #expect(dto.remember == true)
        #expect(dto.byUser == true)
        #expect(dto.uiPhaseWhenClicked == "blue")
    }

    @Test("decision_response response.minimal：decision=deny + ui_phase 省略")
    func decisionResponse_minimal() throws {
        let dto = try Self.decoder().decode(
            DecisionResponseProbe.self, from: Self.extract("decision_response", "response.minimal", field: "result"))
        #expect(dto.decision == .deny)
        #expect(dto.remember == false)
        #expect(dto.uiPhaseWhenClicked == nil)
    }

    @Test("decision_response response.null_optional：ui_phase=null → nil")
    func decisionResponse_nullOptional() throws {
        let dto = try Self.decoder().decode(
            DecisionResponseProbe.self, from: Self.extract("decision_response", "response.null_optional", field: "result"))
        #expect(dto.decision == .deny)
        #expect(dto.byUser == false)
        #expect(dto.uiPhaseWhenClicked == nil)
    }

    // ── sieve.request_decision（GUI 端核心：HipsRequestDecoder 手工解码）─────────

    @Test("sieve.request_decision single.minimal：HipsRequestDecoder 解出 enum 字段")
    func requestDecision_singleMinimal() throws {
        let params = try Self.extract("sieve.request_decision", "request.single.minimal", field: "params")
        let req = try HipsRequestDecoder.decode(id: "test", paramsData: params)
        #expect(req.ruleId == "IN-CR-05")
        #expect(req.severity == .critical)
        #expect(req.direction == .inbound)
        #expect(req.defaultOnTimeout == .block)
        #expect(req.merged == false)
        #expect(req.allowRemember == false)
    }

    @Test("sieve.request_decision single.full：context + recommendation 解码")
    func requestDecision_singleFull() throws {
        let params = try Self.extract("sieve.request_decision", "request.single.full", field: "params")
        let req = try HipsRequestDecoder.decode(id: "test", paramsData: params)
        #expect(req.ruleId == "IN-CR-05")
        #expect(req.severity == .critical)
        #expect(req.context != nil)
        // recommendation：decision=deny / confidence=high
        #expect(req.recommendation?.decision == .deny)
        #expect(req.recommendation?.confidence == .high)
    }

    @Test("sieve.request_decision merged：2 个 issue + 顶层无 rule_id")
    func requestDecision_merged() throws {
        let params = try Self.extract("sieve.request_decision", "request.merged", field: "params")
        let req = try HipsRequestDecoder.decode(id: "test", paramsData: params)
        #expect(req.merged == true)
        #expect(req.ruleId == nil)
        #expect(req.issues.count == 2)
        #expect(req.issues[0].ruleId == "IN-CR-05")
        #expect(req.issues[0].severity == .critical)
        #expect(req.issues[1].ruleId == "IN-GEN-04")
        #expect(req.issues[1].severity == .high)
        #expect(req.severity == .critical)
    }

    // ── sieve.request_decision_canceled（reason 是裸 String，不漂移）─────────────

    @Test("request_decision_canceled minimal：reason=timeout")
    func canceled_minimal() throws {
        let dto = try Self.decoder().decode(
            RequestCanceledParams.self,
            from: Self.extract("sieve.request_decision_canceled", "notification.minimal", field: "params"))
        #expect(dto.reason == "timeout")
    }

    @Test("request_decision_canceled full：reason=upstream_disconnected（daemon 多发 auto_decision，GUI 忽略）")
    func canceled_full() throws {
        let dto = try Self.decoder().decode(
            RequestCanceledParams.self,
            from: Self.extract("sieve.request_decision_canceled", "notification.full", field: "params"))
        #expect(dto.reason == "upstream_disconnected")
    }

    @Test("request_decision_canceled null_optional：reason=timeout")
    func canceled_nullOptional() throws {
        let dto = try Self.decoder().decode(
            RequestCanceledParams.self,
            from: Self.extract("sieve.request_decision_canceled", "notification.null_optional", field: "params"))
        #expect(dto.reason == "timeout")
    }

    // ── sieve.heartbeat（无 params，只验证 method 字段）─────────────────────────

    @Test("sieve.heartbeat：三档均为 {jsonrpc, method}，无 params", arguments: [
        "notification.full", "notification.minimal", "notification.null_optional",
    ])
    func heartbeat(_ name: String) throws {
        let data = try Self.loadFixture("sieve.heartbeat", name)
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["method"] as? String == "sieve.heartbeat")
        #expect(obj["params"] == nil, "heartbeat 不应有 params（SPEC-005 §4）")
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - 跨仓漂移已修复（断言已从 #expect(throws:) 翻转为「解码成功 + 字段正确」）
    //
    // 2026-06-18：daemon 侧按 SPEC-005 修正 D1-D7 全部 7 类漂移后，本段断言从「钉死解码失败」
    // 翻转为正向校验。fixture 副本已与 daemon 权威源逐字节对齐（见 _PIN.md）。
    // 现在「测试通过 = 两仓 wire schema 一致」；若任一侧再次漂移，对应断言会变红。
    // ════════════════════════════════════════════════════════════════════════

    // ── 漂移 D1（已修复）：sieve.hello preset "default"→"standard"（SPEC §5.6 v1→v2）─
    //
    // daemon 已统一发 "standard"，GUI Preset enum 含 .standard，解码成功。

    @Test("【D1 已修复】sieve.hello：preset=\"standard\" 解码成功", arguments: [
        "full", "minimal", "null_optional",
    ])
    func fixed_hello_presetStandard(_ name: String) throws {
        let params = try Self.extract("sieve.hello", name, field: "params")
        let dto = try Self.decoder().decode(HelloParams.self, from: params)
        #expect(dto.preset == .standard)
        #expect(dto.protocolVersion == "v2")
    }

    // ── 漂移 D2（已修复）：sieve.set_preset request.minimal mode "default"→"standard" ─
    //
    // daemon 已发 "standard"，进 GUI Preset enum 成功。full/null_optional 仍是 strict/relaxed。

    @Test("【D2 已修复】sieve.set_preset request.minimal：mode=\"standard\" 解码成功")
    func fixed_setPreset_minimalStandard() throws {
        let params = try Self.extract("sieve.set_preset", "request.minimal", field: "params")
        let dto = try Self.decoder().decode(SetPresetModeProbe.self, from: params)
        #expect(dto.mode == .standard)
    }

    /// set_preset request.full / null_optional 的 mode 是合法 Preset 值（strict/relaxed），应解码成功。
    @Test("sieve.set_preset request.full：mode=strict（合法）")
    func setPreset_fullStrict() throws {
        let params = try Self.extract("sieve.set_preset", "request.full", field: "params")
        let dto = try Self.decoder().decode(SetPresetModeProbe.self, from: params)
        #expect(dto.mode == .strict)
    }

    @Test("sieve.set_preset request.null_optional：mode=relaxed（合法）")
    func setPreset_nullRelaxed() throws {
        let params = try Self.extract("sieve.set_preset", "request.null_optional", field: "params")
        let dto = try Self.decoder().decode(SetPresetModeProbe.self, from: params)
        #expect(dto.mode == .relaxed)
    }

    // ── 漂移 D3（已修复）：sieve.preset_changed —— GUI 删 `preset` 字段，对齐 daemon ─
    //
    // daemon 只发 mode(String)（SPEC §10.1，无 preset）。GUI PresetChangedParams 已删
    // `preset` 字段，仅保留 mode，解码成功。

    @Test("【D3 已修复】sieve.preset_changed：仅 mode 字段，解码成功", arguments: [
        ("notification.full", "custom", "gui"),
        ("notification.minimal", "standard", "gui"),
        ("notification.null_optional", "strict", "config_reload"),
    ])
    func fixed_presetChanged_modeOnly(_ name: String, _ expectedMode: String, _ expectedSource: String) throws {
        let params = try Self.extract("sieve.preset_changed", name, field: "params")
        let dto = try Self.decoder().decode(PresetChangedParams.self, from: params)
        #expect(dto.mode == expectedMode)
        #expect(dto.source == expectedSource)
    }

    @Test("【D3 已修复】sieve.preset_changed null_optional：origin_request_id=null → nil")
    func fixed_presetChanged_nullOriginRequestId() throws {
        let params = try Self.extract("sieve.preset_changed", "notification.null_optional", field: "params")
        let dto = try Self.decoder().decode(PresetChangedParams.self, from: params)
        #expect(dto.originRequestId == nil)
    }

    // ── 漂移 D4（已修复）：sieve.paused_changed —— daemon 已发 `source` ───────────
    //
    // daemon 现发 source(required) + reason。GUI PausedChangedParams.source 必填，解码成功。

    @Test("【D4 已修复】sieve.paused_changed：含 source 字段，解码成功", arguments: [
        ("notification.full", true), ("notification.minimal", true), ("notification.null_optional", false),
    ])
    func fixed_pausedChanged_withSource(_ name: String, _ expectedPaused: Bool) throws {
        let params = try Self.extract("sieve.paused_changed", name, field: "params")
        let dto = try Self.decoder().decode(PausedChangedParams.self, from: params)
        #expect(dto.paused == expectedPaused)
        #expect(dto.source == "gui")
    }

    @Test("【D4 已修复】sieve.paused_changed full：paused_until 解析 + applies_to 3 项")
    func fixed_pausedChanged_full() throws {
        let params = try Self.extract("sieve.paused_changed", "notification.full", field: "params")
        let dto = try Self.decoder().decode(PausedChangedParams.self, from: params)
        #expect(dto.pausedUntil != nil)
        #expect(dto.appliesTo.count == 3)
        #expect(dto.reason == "user_request")
    }

    // ── 漂移 D5（已修复）：sieve.notify_status_bar —— GUI DTO 重写对齐 StatusBarNotify ─
    //
    // GUI EventNotifyParams 已重写为 daemon StatusBarNotify schema（SPEC §10.1）：
    // notify_id/created_at/kind/title/detail?/rule_id?/auto_dismiss_seconds，解码成功。

    @Test("【D5 已修复】sieve.notify_status_bar full：outbound_redacted + detail + rule_id")
    func fixed_notifyStatusBar_full() throws {
        let params = try Self.extract("sieve.notify_status_bar", "notification.full", field: "params")
        let dto = try Self.decoder().decode(EventNotifyParams.self, from: params)
        #expect(dto.kind == .outboundRedacted)
        #expect(dto.title == "OUT-01 API 密钥已自动脱敏")
        #expect(dto.ruleId == "OUT-01-API-KEY")
        #expect(dto.detail != nil)
        #expect(dto.autoDismissSeconds == 5)
        #expect(dto.notifyId == "01900000-0000-7001-0000-000000000001")
    }

    @Test("【D5 已修复】sieve.notify_status_bar minimal：sequence_hit + 省略 detail/rule_id")
    func fixed_notifyStatusBar_minimal() throws {
        let params = try Self.extract("sieve.notify_status_bar", "notification.minimal", field: "params")
        let dto = try Self.decoder().decode(EventNotifyParams.self, from: params)
        #expect(dto.kind == .sequenceHit)
        #expect(dto.detail == nil)
        #expect(dto.ruleId == nil)
        #expect(dto.autoDismissSeconds == 5)
    }

    @Test("【D5 已修复】sieve.notify_status_bar null_optional：generic + detail/rule_id=null + auto_dismiss=0")
    func fixed_notifyStatusBar_nullOptional() throws {
        let params = try Self.extract("sieve.notify_status_bar", "notification.null_optional", field: "params")
        let dto = try Self.decoder().decode(EventNotifyParams.self, from: params)
        #expect(dto.kind == .generic)
        #expect(dto.detail == nil)
        #expect(dto.ruleId == nil)
        #expect(dto.autoDismissSeconds == 0)
    }

    // ── 漂移 D6（已修复）：sieve.purge_history —— purged_at 改为 ISO8601 字符串 ────
    //
    // daemon 改发 ISO8601 串（SPEC §11B Timestamp）。GUI PurgeHistoryResult.purgedAt
    // 本就当 ISO 串解，解码成功。

    @Test("【D6 已修复】sieve.purge_history：purged_at ISO8601 串解码成功", arguments: [
        ("response.full", UInt64(4721)), ("response.minimal", UInt64(0)), ("response.null_optional", UInt64(0)),
    ])
    func fixed_purgeHistory_purgedAtISO(_ name: String, _ expectedRows: UInt64) throws {
        let result = try Self.extract("sieve.purge_history", name, field: "result")
        let dto = try Self.decoder().decode(PurgeHistoryResult.self, from: result)
        #expect(dto.rowsDeleted == expectedRows)
        // purged_at 是 2025-05-04T00:00:00.xxxZ → 应成功解析为非默认 Date
        #expect(dto.purgedAt.timeIntervalSince1970 > 1_700_000_000)
    }

    // ── 漂移 D7（已修复）：sieve.evaluate response.full —— would_recommendation 改对象 ─
    //
    // GUI Match.wouldRecommendation 改为 Recommendation?（SPEC §6.1.4 对象 {decision,
    // confidence, reason}）。full 携带对象，解码成功。

    @Test("【D7 已修复】sieve.evaluate response.full：would_recommendation 是 Recommendation 对象")
    func fixed_evaluate_wouldRecommendationObject() throws {
        let result = try Self.extract("sieve.evaluate", "response.full", field: "result")
        let dto = try Self.decoder().decode(EvaluateResult.self, from: result)
        #expect(dto.matches.count == 1)
        let m = dto.matches[0]
        #expect(m.ruleId == "IN-CR-05")
        #expect(m.severity == .critical)
        #expect(m.wouldDecision == "deny")
        #expect(m.wouldRecommendation?.decision == .deny)
        #expect(m.wouldRecommendation?.confidence == .high)
        #expect(m.wouldRecommendation?.reason == "检测到高风险签名操作")
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - 无 GUI DTO 的 method（仅校验 fixture 是合法 JSON，记录覆盖缺口）
    //
    // 以下 method 在 GUI 端无消费 DTO（fire-and-forget 或未实现 handler），
    // 仅断言副本是合法 JSON，保证它们随 daemon fixture 一起被纳入复制+校验范围。
    // 是否需要补 DTO 由 daemon/GUI 协商，不在本测试擅自新增（见 _PIN.md 缺口清单）。
    // ════════════════════════════════════════════════════════════════════════

    @Test("无 DTO method：fixture 仍是合法 JSON", arguments: [
        ("sieve.reload_user_rules", "notification.full"),
        ("sieve.reload_user_rules", "notification.minimal"),
        ("sieve.reload_user_rules", "notification.null_optional"),
        ("sieve.remove_graylist", "response.full"),
        ("sieve.remove_graylist", "response.minimal"),
        ("sieve.remove_graylist", "response.null_optional"),
        ("sieve.set_preset_overrides", "response.full"),
        ("sieve.set_preset_overrides", "response.minimal"),
        ("sieve.set_preset_overrides", "response.null_optional"),
    ])
    func noDTOMethod_validJSON(_ method: String, _ name: String) throws {
        let data = try Self.loadFixture(method, name)
        let obj = try? JSONSerialization.jsonObject(with: data)
        #expect(obj != nil, "\(method)/\(name) 应是合法 JSON")
    }

    // ════════════════════════════════════════════════════════════════════════
    // MARK: - 生成式守门：fixture 副本总数与 daemon 权威源对齐
    // ════════════════════════════════════════════════════════════════════════

    /// daemon 仓 fixtures/v2 的 19 个 method 目录 → 各自的 fixture 文件名集合。
    /// 这是「与 daemon 权威源对齐」的清单快照：daemon 新增/删除 fixture 时，本表必须同步，
    /// 否则 fixtureCount 变红，强制有人来对账（防止 GUI 副本悄悄落后于 daemon）。
    private static let expectedFixtures: [String: [String]] = [
        "decision_response": ["response.full", "response.minimal", "response.null_optional"],
        "sieve.evaluate": ["request.full", "request.minimal", "request.null_optional",
                           "response.full", "response.minimal", "response.null_optional"],
        "sieve.health": ["request.minimal", "response.full", "response.minimal", "response.null_optional"],
        "sieve.heartbeat": ["notification.full", "notification.minimal", "notification.null_optional"],
        "sieve.hello": ["full", "minimal", "null_optional"],
        "sieve.list_graylist": ["request.full", "request.minimal", "request.null_optional",
                               "response.full", "response.minimal", "response.null_optional"],
        "sieve.list_rules": ["request.minimal", "response.full", "response.minimal", "response.null_optional"],
        "sieve.notify_status_bar": ["notification.full", "notification.minimal", "notification.null_optional"],
        "sieve.paused_changed": ["notification.full", "notification.minimal", "notification.null_optional"],
        "sieve.preset_changed": ["notification.full", "notification.minimal", "notification.null_optional"],
        "sieve.purge_history": ["request.minimal", "response.full", "response.minimal", "response.null_optional"],
        "sieve.reload_config": ["request.full", "request.minimal", "request.null_optional",
                               "response.full", "response.minimal", "response.null_optional"],
        "sieve.reload_user_rules": ["notification.full", "notification.minimal", "notification.null_optional"],
        "sieve.remove_graylist": ["request.full", "request.minimal", "request.null_optional",
                                 "response.full", "response.minimal", "response.null_optional"],
        "sieve.request_decision": ["request.merged", "request.single.full", "request.single.minimal"],
        "sieve.request_decision_canceled": ["notification.full", "notification.minimal", "notification.null_optional"],
        "sieve.set_paused": ["request.full", "request.minimal", "request.null_optional",
                            "response.full", "response.minimal", "response.null_optional"],
        "sieve.set_preset": ["request.full", "request.minimal", "request.null_optional",
                            "response.full", "response.minimal", "response.null_optional"],
        "sieve.set_preset_overrides": ["request.full", "request.minimal", "request.null_optional",
                                      "response.full", "response.minimal", "response.null_optional"],
    ]

    @Test("fixture 副本总数 == 81 且每个文件都打包就位（与 daemon 仓 fixtures/v2 对齐）")
    func fixtureCount() throws {
        var total = 0
        var missing: [String] = []
        for (method, names) in Self.expectedFixtures {
            for name in names {
                total += 1
                if Bundle.module.url(
                    forResource: name, withExtension: "json",
                    subdirectory: "Fixtures/v2/\(method)") == nil {
                    missing.append("\(method)/\(name).json")
                }
            }
        }
        #expect(total == 81, "期望清单应列 81 个 fixture；实际 \(total)")
        #expect(missing.isEmpty, "以下 fixture 副本未打包/缺失：\(missing.joined(separator: ", "))")
    }
}

// MARK: - 探针 DTO（仅本测试用，复用 GUI 既有 enum 校验跨仓 enum 取值）

/// 探 set_preset request 的 mode 字符串能否进 GUI `Preset` enum（漂移 D2）。
private struct SetPresetModeProbe: Decodable {
    let mode: Preset
}

/// 探 decision_response result 的 decision enum 与 ui_phase 字符串（GUI 实际走手工编码，
/// 此 probe 复用 GUI `Decision` enum 校验 wire 值落在合法集合内）。
private struct DecisionResponseProbe: Decodable {
    let requestId: String
    let decision: Decision
    let byUser: Bool
    let remember: Bool
    let uiPhaseWhenClicked: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case decision
        case byUser = "by_user"
        case remember
        case uiPhaseWhenClicked = "ui_phase_when_clicked"
    }
}
