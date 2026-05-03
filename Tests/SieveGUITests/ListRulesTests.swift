import Testing
import Foundation
@testable import SieveGUICore

@Suite("sieve.list_rules 解码 + 错误分支（SPEC-005 §11A）")
struct ListRulesTests {

    // MARK: - ListRulesResult 解码

    @Test("minimal 单条规则解码成功")
    func decode_minimal_rule() throws {
        let json = """
        {
          "rules": [
            {
              "rule_id": "IN-CR-01",
              "title": "BIP39 助记词检测",
              "severity": "critical",
              "direction": "inbound",
              "disposition": "gui_popup",
              "default_on_timeout": "block",
              "timeout_seconds": 30,
              "critical_lock": true,
              "enabled": true,
              "rule_kind": "system",
              "description": "检测入站流量中出现的 BIP39 助记词序列"
            }
          ]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ListRulesResult.self, from: json)
        #expect(result.rules.count == 1)
        let rule = result.rules[0]
        #expect(rule.ruleId == "IN-CR-01")
        #expect(rule.title == "BIP39 助记词检测")
        #expect(rule.severity == .critical)
        #expect(rule.direction == .inbound)
        #expect(rule.disposition == .guiPopup)
        #expect(rule.defaultOnTimeout == .block)
        #expect(rule.timeoutSeconds == 30)
        #expect(rule.criticalLock == true)
        #expect(rule.enabled == true)
        #expect(rule.ruleKind == .system)
        #expect(rule.description == "检测入站流量中出现的 BIP39 助记词序列")
    }

    @Test("full 多条规则、含 null 字段解码成功")
    func decode_full_rules() throws {
        let json = """
        {
          "rules": [
            {
              "rule_id": "IN-CR-01",
              "title": "BIP39",
              "severity": "critical",
              "direction": "inbound",
              "disposition": "gui_popup",
              "default_on_timeout": "block",
              "timeout_seconds": 30,
              "critical_lock": true,
              "enabled": true,
              "rule_kind": "system",
              "description": null
            },
            {
              "rule_id": "OUT-01",
              "title": "自动脱敏",
              "severity": "high",
              "direction": "outbound",
              "disposition": "auto_redact",
              "default_on_timeout": null,
              "timeout_seconds": null,
              "critical_lock": false,
              "enabled": false,
              "rule_kind": "user",
              "description": "用户自定义规则"
            }
          ]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ListRulesResult.self, from: json)
        #expect(result.rules.count == 2)

        let r0 = result.rules[0]
        #expect(r0.description == nil)
        #expect(r0.defaultOnTimeout == .block)
        #expect(r0.timeoutSeconds == 30)

        let r1 = result.rules[1]
        #expect(r1.ruleId == "OUT-01")
        #expect(r1.severity == .high)
        #expect(r1.direction == .outbound)
        #expect(r1.disposition == .autoRedact)
        #expect(r1.defaultOnTimeout == nil)
        #expect(r1.timeoutSeconds == nil)
        #expect(r1.criticalLock == false)
        #expect(r1.enabled == false)
        #expect(r1.ruleKind == .user)
        #expect(r1.description == "用户自定义规则")
    }

    @Test("critical_lock=true 行字段正确")
    func decode_critical_lock_row() throws {
        let json = """
        {
          "rules": [
            {
              "rule_id": "OUT-07",
              "title": "出站 Critical 规则",
              "severity": "critical",
              "direction": "outbound",
              "disposition": "gui_popup",
              "default_on_timeout": "redact",
              "timeout_seconds": 60,
              "critical_lock": true,
              "enabled": true,
              "rule_kind": "system",
              "description": null
            }
          ]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ListRulesResult.self, from: json)
        let rule = result.rules[0]
        #expect(rule.criticalLock == true)
        #expect(rule.severity == .critical)
        #expect(rule.defaultOnTimeout == .redact)
        #expect(rule.timeoutSeconds == 60)
    }

    @Test("空规则列表解码成功（rules: []）")
    func decode_empty_rules() throws {
        let json = #"{"rules":[]}"#.data(using: .utf8)!
        let result = try JSONDecoder().decode(ListRulesResult.self, from: json)
        #expect(result.rules.isEmpty)
    }

    // MARK: - RuleSummary.id 代理

    @Test("RuleSummary.id == ruleId（Identifiable 代理）")
    func identifiable_id() throws {
        let json = """
        {
          "rules": [
            {
              "rule_id": "IN-CR-05",
              "title": "测试",
              "severity": "low",
              "direction": "inbound",
              "disposition": "status_bar",
              "default_on_timeout": null,
              "timeout_seconds": null,
              "critical_lock": false,
              "enabled": true,
              "rule_kind": "system"
            }
          ]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ListRulesResult.self, from: json)
        let rule = result.rules[0]
        #expect(rule.id == "IN-CR-05")
        #expect(rule.id == rule.ruleId)
    }
}
