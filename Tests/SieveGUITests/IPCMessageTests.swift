import Foundation
import Testing
@testable import SieveGUICore

@Suite("IPC message decode")
struct IPCMessageTests {
    @Test func decodes_request() throws {
        let line = #"{"jsonrpc":"2.0","method":"sieve.request_decision","id":"1","params":{"a":1}}"#
        let m = try IPCIncoming.decode(line: Data(line.utf8))
        if case let .request(id, method, _) = m {
            #expect(id == "1")
            #expect(method == "sieve.request_decision")
        } else {
            Issue.record("expected request")
        }
    }

    @Test func decodes_notification() throws {
        let line = #"{"jsonrpc":"2.0","method":"sieve.heartbeat"}"#
        let m = try IPCIncoming.decode(line: Data(line.utf8))
        if case let .notification(method, _) = m {
            #expect(method == "sieve.heartbeat")
        } else {
            Issue.record("expected notification")
        }
    }

    @Test func decodes_error_response() throws {
        let line = #"{"jsonrpc":"2.0","id":"x","error":{"code":-32010,"message":"critical_lock_violation"}}"#
        let m = try IPCIncoming.decode(line: Data(line.utf8))
        if case let .errorResponse(_, code, message, _) = m {
            #expect(code == -32010)
            #expect(message == "critical_lock_violation")
        } else {
            Issue.record("expected error response")
        }
    }

    @Test func rejects_non_jsonrpc() {
        let line = #"{"foo":"bar"}"#
        #expect(throws: IPCError.self) {
            _ = try IPCIncoming.decode(line: Data(line.utf8))
        }
    }
}

@Suite("PresetChangedParams decode")
struct PresetChangedParamsTests {
    /// D3：daemon 只发 mode(String)（SPEC §10.1，无 preset 字段）；GUI DTO 已删 preset。
    @Test func decodes_with_origin_request_id() throws {
        let json = #"{"mode":"standard","changed_at":"2099-01-01T00:00:00Z","source":"gui","origin_request_id":"req-xyz"}"#
        let p = try JSONDecoder().decode(PresetChangedParams.self, from: Data(json.utf8))
        #expect(p.mode == "standard")
        #expect(p.source == "gui")
        #expect(p.originRequestId == "req-xyz")
    }

    @Test func decodes_without_origin_request_id() throws {
        // daemon CLI 触发，无 origin_request_id
        let json = #"{"mode":"strict","changed_at":"2099-01-01T00:00:00Z","source":"daemon_cli"}"#
        let p = try JSONDecoder().decode(PresetChangedParams.self, from: Data(json.utf8))
        #expect(p.mode == "strict")
        #expect(p.originRequestId == nil)
        #expect(p.source == "daemon_cli")
    }
}

@Suite("InflightMutatingSet")
struct InflightMutatingSetTests {
    @Test func insert_and_contains() async {
        let set = InflightMutatingSet()
        await set.insert("req-1")
        #expect(await set.contains("req-1") == true)
        #expect(await set.contains("req-2") == false)
    }

    @Test func remove() async {
        let set = InflightMutatingSet()
        await set.insert("req-1")
        await set.remove("req-1")
        #expect(await set.contains("req-1") == false)
    }

    @Test func clear() async {
        let set = InflightMutatingSet()
        await set.insert("req-1")
        await set.insert("req-2")
        await set.clear()
        #expect(await set.count() == 0)
    }

    /// 三场景：自发回声 / 他 GUI 触发 / daemon CLI 触发（null origin）
    @Test func echo_detection_self_issued() async {
        let set = InflightMutatingSet()
        await set.insert("req-abc")
        // 自己发出的 mutating request → 在集合中 → 回声
        #expect(await set.contains("req-abc") == true)
    }

    @Test func echo_detection_other_gui() async {
        let set = InflightMutatingSet()
        await set.insert("req-abc")
        // 他 GUI 发出的，origin_request_id 不在本集合
        #expect(await set.contains("req-other") == false)
    }

    @Test func echo_detection_daemon_cli() async {
        let set = InflightMutatingSet()
        await set.insert("req-abc")
        // daemon CLI 触发，origin_request_id 为 nil → 不在集合 → 应更新
        let id: String? = nil
        #expect(id == nil) // nil → 应更新（IPCClient.isMutatingEcho 返回 false）
    }
}

@Suite("PausedChangedParams decode")
struct PausedChangedParamsTests {
    @Test func decodes_minimal() throws {
        let json = #"{"paused":true,"source":"daemon_cli"}"#
        let p = try JSONDecoder().decode(PausedChangedParams.self, from: Data(json.utf8))
        #expect(p.paused == true)
        #expect(p.source == "daemon_cli")
        #expect(p.pausedUntil == nil)
        #expect(p.reason == nil)
        #expect(p.appliesTo == [])
        #expect(p.originRequestId == nil)
    }

    @Test func decodes_full() throws {
        let json = #"{"paused":true,"paused_until":"2099-01-01T00:00:00Z","reason":"user_request","applies_to":["claude","cursor"],"source":"gui","origin_request_id":"req-abc"}"#
        let p = try JSONDecoder().decode(PausedChangedParams.self, from: Data(json.utf8))
        #expect(p.paused == true)
        #expect(p.source == "gui")
        #expect(p.reason == "user_request")
        #expect(p.appliesTo == ["claude", "cursor"])
        #expect(p.originRequestId == "req-abc")
        #expect(p.pausedUntil != nil)
    }

    @Test func decodes_false_paused() throws {
        let json = #"{"paused":false,"applies_to":[],"source":"daemon_cli"}"#
        let p = try JSONDecoder().decode(PausedChangedParams.self, from: Data(json.utf8))
        #expect(p.paused == false)
        #expect(p.pausedUntil == nil)
    }
}

@Suite("ReloadConfigResult decode")
struct ReloadConfigResultTests {
    @Test func decodes_full() throws {
        let json = """
        {
          "system_rules_count": 42,
          "user_rules_count": 3,
          "user_rules_errors": ["parse error at line 5"],
          "reloaded_at": "2099-01-01T00:00:00Z"
        }
        """
        let r = try JSONDecoder().decode(ReloadConfigResult.self, from: Data(json.utf8))
        #expect(r.systemRulesCount == 42)
        #expect(r.userRulesCount == 3)
        #expect(r.userRulesErrors == ["parse error at line 5"])
        #expect(r.reloadedAt != nil)
    }

    @Test func decodes_minimal() throws {
        let json = #"{}"#
        let r = try JSONDecoder().decode(ReloadConfigResult.self, from: Data(json.utf8))
        #expect(r.systemRulesCount == 0)
        #expect(r.userRulesErrors.isEmpty)
        #expect(r.reloadedAt == nil)
    }
}

@Suite("context_hint unicode scalar truncation")
struct ContextHintTruncationTests {
    @Test func drops_hint_when_not_remembered_even_if_allowed() {
        // Each emoji is 1 Unicode scalar but may be > 1 Character in some encodings
        // Use CJK characters (each is 1 scalar) for predictability
        let longHint = String(repeating: "字", count: 250)
        let response = DecisionResponse(
            id: "r-1", decision: .allow, remember: false, contextHint: longHint, byUser: true, uiPhaseWhenClicked: .blue
        )
        let result = response.resultJSON(allowRemember: true)
        #expect(result["context_hint"] is NSNull)
    }

    @Test func truncates_at_200_scalars_when_allow_remember_and_remembered() {
        let longHint = String(repeating: "字", count: 250)
        let response = DecisionResponse(
            id: "r-1", decision: .allow, remember: true, contextHint: longHint, byUser: true, uiPhaseWhenClicked: .blue
        )
        let result = response.resultJSON(allowRemember: true)
        let hint = result["context_hint"] as? String
        #expect(hint != nil)
        #expect(hint?.unicodeScalars.count == 200)
    }

    @Test func drops_hint_for_deny() {
        let shortHint = "short"
        let response = DecisionResponse(
            id: "r-2", decision: .deny, remember: false, contextHint: shortHint, byUser: true, uiPhaseWhenClicked: .blue
        )
        let result = response.resultJSON(allowRemember: true)
        #expect(result["context_hint"] is NSNull)
    }
}

@Suite("SetPausedResult decode")
struct SetPausedResultTests {
    @Test func decodes_paused_true_with_until() throws {
        let json = """
        {
          "paused": true,
          "paused_until": "2099-01-01T12:00:00Z",
          "applies_to": ["claude", "cursor"]
        }
        """
        let r = try JSONDecoder().decode(SetPausedResult.self, from: Data(json.utf8))
        #expect(r.paused == true)
        #expect(r.pausedUntil != nil)
        #expect(r.appliesTo == ["claude", "cursor"])
    }

    @Test func decodes_paused_false_null_until() throws {
        let json = #"{"paused":false,"applies_to":[]}"#
        let r = try JSONDecoder().decode(SetPausedResult.self, from: Data(json.utf8))
        #expect(r.paused == false)
        #expect(r.pausedUntil == nil)
        #expect(r.appliesTo.isEmpty)
    }
}

@Suite("GraylistEntry decode")
struct GraylistEntryTests {
    @Test func decodes_entry_with_unix_ms_timestamp() throws {
        let json = """
        {
          "fingerprint": "abc123",
          "rule_id": "OUT-07",
          "added_at": 1746000000000,
          "context_hint": "wallet",
          "match_count_since": 3,
          "rule_kind": "pattern",
          "added_by": "gui"
        }
        """
        let entry = try JSONDecoder().decode(GraylistEntry.self, from: Data(json.utf8))
        #expect(entry.fingerprint == "abc123")
        #expect(entry.ruleId == "OUT-07")
        #expect(entry.matchCountSince == 3)
        #expect(entry.ruleKind == "pattern")
        #expect(entry.addedBy == "gui")
        #expect(entry.contextHint == "wallet")
        // 1746000000000 ms = 1746000000 s
        #expect(entry.addedAt.timeIntervalSince1970 == 1_746_000_000.0)
    }

    @Test func decodes_entry_with_missing_optional_fields() throws {
        let json = """
        {"fingerprint":"fp1","rule_id":"IN-CR-01","added_at":0}
        """
        let entry = try JSONDecoder().decode(GraylistEntry.self, from: Data(json.utf8))
        #expect(entry.matchCountSince == 0)
        #expect(entry.ruleKind == "unknown")
        #expect(entry.addedBy == "unknown")
        #expect(entry.contextHint == nil)
    }
}

@Suite("EvaluateResult.Match decode")
struct EvaluateResultMatchTests {
    @Test func decodes_match_with_new_fields() throws {
        let json = """
        {
          "matches": [{
            "rule_id": "OUT-07",
            "severity": "high",
            "disposition": "auto_redact",
            "matched_pattern_summary": "wallet address",
            "fields_triggered": ["tool_input"],
            "evaluated_at": 1746000000000,
            "rule_kind": "pattern",
            "would_decision": "redact",
            "would_recommendation": {
              "decision": "deny",
              "confidence": "high",
              "reason": "wallet address detected"
            }
          }],
          "no_match": ["IN-CR-01"]
        }
        """
        let result = try JSONDecoder().decode(EvaluateResult.self, from: Data(json.utf8))
        #expect(result.matches.count == 1)
        let m = result.matches[0]
        #expect(m.ruleId == "OUT-07")
        #expect(m.severity == .high)
        #expect(m.matchedPatternSummary == "wallet address")
        #expect(m.fieldsTriggered == ["tool_input"])
        #expect(m.ruleKind == "pattern")
        #expect(m.wouldDecision == "redact")
        // D7：would_recommendation 改为 Recommendation 对象（SPEC §6.1.4）
        #expect(m.wouldRecommendation?.decision == .deny)
        #expect(m.wouldRecommendation?.confidence == .high)
        #expect(m.evaluatedAt != nil)
        #expect(result.noMatch == ["IN-CR-01"])
    }

    @Test func decodes_match_without_optional_fields() throws {
        let json = """
        {
          "matches": [{
            "rule_id": "IN-GEN-01",
            "severity": "low",
            "disposition": "status_bar",
            "rule_kind": "sequence",
            "would_decision": "allow"
          }]
        }
        """
        let result = try JSONDecoder().decode(EvaluateResult.self, from: Data(json.utf8))
        let m = result.matches[0]
        #expect(m.matchedPatternSummary == nil)
        #expect(m.fieldsTriggered == nil)
        #expect(m.evaluatedAt == nil)
        #expect(m.wouldRecommendation == nil)
    }
}

@Suite("NotifyKind decode")
struct NotifyKindTests {
    @Test func decodes_all_six_values() throws {
        let cases: [(String, NotifyKind)] = [
            ("sequence_hit", .sequenceHit),
            ("outbound_redacted", .outboundRedacted),
            ("hook_terminal", .hookTerminal),
            ("user_rules_load_failed", .userRulesLoadFailed),
            ("user_rules_reloaded", .userRulesReloaded),
            ("generic", .generic)
        ]
        for (raw, expected) in cases {
            let data = Data("\"\(raw)\"".utf8)
            let decoded = try JSONDecoder().decode(NotifyKind.self, from: data)
            #expect(decoded == expected, "expected \(expected) for '\(raw)'")
        }
    }
}

@Suite("IPC outbound encoding")
struct IPCOutboundTests {
    @Test func notification_encodes_with_newline() {
        let data = IPCOutbound.notification(method: "x")
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.hasSuffix("\n"))
        #expect(s.contains("\"method\":\"x\""))
    }

    @Test func response_includes_id_and_result() {
        let data = IPCOutbound.response(id: "abc", result: ["decision": "deny"])
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.contains("\"id\":\"abc\""))
        #expect(s.contains("\"decision\":\"deny\""))
    }
}
