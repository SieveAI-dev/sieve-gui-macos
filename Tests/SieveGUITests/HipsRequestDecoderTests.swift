import Testing
import Foundation
@testable import SieveGUICore

@Suite("HipsRequestDecoder")
struct HipsRequestDecoderTests {
    @Test func decodes_single_issue_signing() throws {
        let json = """
        {
          "request_id": "abc-123",
          "rule_id": "IN-CR-05",
          "title": "签名工具调用",
          "severity": "critical",
          "direction": "inbound",
          "disposition": "gui_popup",
          "timeout_seconds": 120,
          "default_on_timeout": "block",
          "allow_remember": false,
          "merged": false,
          "context": {
            "template": "signing_tool_use",
            "tool_name": "signTransaction",
            "chain": "Ethereum",
            "chain_id": 1,
            "flags": { "infinite_amount": true, "deadline_zero": true, "approve_all": false }
          },
          "recommendation": { "decision": "deny", "confidence": "high", "reason": "phishing pattern" }
        }
        """
        let req = try HipsRequestDecoder.decode(id: "abc-123", paramsData: Data(json.utf8))
        #expect(req.id == "abc-123")
        #expect(req.severity == .critical)
        #expect(req.direction == .inbound)
        #expect(req.allowRemember == false)
        #expect(req.merged == false)
        #expect(req.recommendation?.confidence == .high)
        if case .signingToolUse(let s) = req.context {
            #expect(s.toolName == "signTransaction")
            #expect(s.flags?.infiniteAmount == true)
        } else {
            Issue.record("expected signing_tool_use template")
        }
    }

    @Test func decodes_merged_with_critical() throws {
        let json = """
        {
          "request_id": "m-1",
          "title": "Sieve 检测到 2 个安全问题",
          "severity": "critical",
          "direction": "inbound",
          "disposition": "gui_popup",
          "timeout_seconds": 30,
          "default_on_timeout": "block",
          "allow_remember": false,
          "merged": true,
          "issues": [
            {
              "issue_id": "i-1",
              "rule_id": "IN-CR-05",
              "title": "签名工具调用",
              "severity": "critical",
              "allow_remember": false,
              "context": { "template": "signing_tool_use", "tool_name": "x", "chain": "Ethereum" }
            },
            {
              "issue_id": "i-2",
              "rule_id": "IN-GEN-04",
              "title": "Markdown 外链",
              "severity": "high",
              "allow_remember": true,
              "context": { "template": "markdown_exfil", "markdown_snippet": "x", "urls": ["https://x"] }
            }
          ]
        }
        """
        let req = try HipsRequestDecoder.decode(id: "m-1", paramsData: Data(json.utf8))
        #expect(req.merged == true)
        #expect(req.issues.count == 2)
        #expect(req.hasCriticalIssue == true)
    }

    @Test func unknown_template_falls_back_to_generic() throws {
        let json = """
        {
          "request_id": "u-1",
          "rule_id": "X",
          "title": "x",
          "severity": "low",
          "direction": "outbound",
          "disposition": "gui_popup",
          "timeout_seconds": 10,
          "default_on_timeout": "allow",
          "allow_remember": true,
          "merged": false,
          "context": { "template": "future_template_v9", "foo": "bar" }
        }
        """
        let req = try HipsRequestDecoder.decode(id: "u-1", paramsData: Data(json.utf8))
        if case .generic = req.context {
            // ok
        } else {
            Issue.record("expected generic fallback")
        }
    }

    // MARK: - SPEC-005 §6.1 v2 wire DTO fixture tests

    /// §6.1.1 单 issue minimal（只含 required 字段）
    @Test func v2_single_issue_minimal() throws {
        let json = """
        {
          "request_id": "8f3a2b91-7c4e-4d8f-9b21-1a3c5e7f9d02",
          "rule_id": "IN-CR-05",
          "title": "签名工具调用：signTransaction",
          "severity": "critical",
          "direction": "inbound",
          "disposition": "gui_popup",
          "timeout_seconds": 120,
          "default_on_timeout": "block",
          "allow_remember": false,
          "merged": false,
          "received_at_daemon": "2026-05-02T15:03:11.234Z",
          "source_agent": "claude",
          "origin_chain": [],
          "source_channel": null,
          "explicit_chain_depth": 0
        }
        """
        let req = try HipsRequestDecoder.decode(id: "8f3a2b91-7c4e-4d8f-9b21-1a3c5e7f9d02", paramsData: Data(json.utf8))
        #expect(req.requestId == "8f3a2b91-7c4e-4d8f-9b21-1a3c5e7f9d02")
        #expect(req.ruleId == "IN-CR-05")
        #expect(req.severity == .critical)
        #expect(req.direction == .inbound)
        #expect(req.timeoutSeconds == 120)
        #expect(req.defaultOnTimeout == .block)
        #expect(req.allowRemember == false)
        #expect(req.merged == false)
        #expect(req.receivedAtDaemon != nil)
        #expect(req.context == nil)
        #expect(req.recommendation == nil)
        #expect(req.issues.isEmpty)
        // 防 regression：created_at / responded_at 字段名不应影响解析
        #expect(req.receivedAtDaemon != nil, "received_at_daemon 必须正确解析，不应依赖 created_at")
    }

    /// §6.1.1 单 issue full（含全部 optional 字段）
    @Test func v2_single_issue_full() throws {
        let json = """
        {
          "request_id": "8f3a2b91-7c4e-4d8f-9b21-1a3c5e7f9d02",
          "rule_id": "IN-CR-05",
          "title": "签名工具调用：signTransaction",
          "severity": "critical",
          "direction": "inbound",
          "disposition": "gui_popup",
          "timeout_seconds": 120,
          "default_on_timeout": "block",
          "allow_remember": false,
          "merged": false,
          "received_at_daemon": "2026-05-02T15:03:11.234Z",
          "context": {
            "template": "signing_tool_use",
            "tool_name": "signTransaction",
            "chain": "Ethereum",
            "chain_id": 1,
            "typed_data": { "domain": {}, "message": {} },
            "flags": { "infinite_amount": true, "deadline_zero": true, "approve_all": false }
          },
          "recommendation": {
            "decision": "deny",
            "confidence": "high",
            "reason": "deadline=0 + 无限 amount 是 Permit2 钓鱼经典模式"
          },
          "source_agent": "claude",
          "origin_chain": [
            { "agent": "claude", "action": "delegate", "timestamp": "2026-05-02T15:03:09.123Z" }
          ],
          "source_channel": null,
          "explicit_chain_depth": 1
        }
        """
        let req = try HipsRequestDecoder.decode(id: "8f3a2b91-7c4e-4d8f-9b21-1a3c5e7f9d02", paramsData: Data(json.utf8))
        #expect(req.severity == .critical)
        #expect(req.allowRemember == false)
        #expect(req.merged == false)
        #expect(req.receivedAtDaemon != nil)
        #expect(req.recommendation?.decision == .deny)
        #expect(req.recommendation?.confidence == .high)
        #expect(req.recommendation?.reason == "deadline=0 + 无限 amount 是 Permit2 钓鱼经典模式")
        if case .signingToolUse(let s) = req.context {
            #expect(s.toolName == "signTransaction")
            #expect(s.chain == "Ethereum")
            #expect(s.chainId == 1)
            #expect(s.flags?.infiniteAmount == true)
            #expect(s.flags?.deadlineZero == true)
            #expect(s.flags?.approveAll == false)
        } else {
            Issue.record("expected signing_tool_use context")
        }
    }

    /// §6.1.1 单 issue null_optional（optional 字段显式 null）
    @Test func v2_single_issue_null_optional() throws {
        let json = """
        {
          "request_id": "null-opt-1",
          "rule_id": "IN-GEN-04",
          "title": "Markdown 图片外链",
          "severity": "high",
          "direction": "inbound",
          "disposition": "gui_popup",
          "timeout_seconds": 60,
          "default_on_timeout": "block",
          "allow_remember": true,
          "merged": false,
          "received_at_daemon": "2026-05-02T15:03:11.234Z",
          "context": null,
          "recommendation": null,
          "source_agent": "claude",
          "origin_chain": [],
          "source_channel": null,
          "explicit_chain_depth": null
        }
        """
        let req = try HipsRequestDecoder.decode(id: "null-opt-1", paramsData: Data(json.utf8))
        #expect(req.severity == .high)
        #expect(req.allowRemember == true)
        #expect(req.merged == false)
        #expect(req.receivedAtDaemon != nil)
        #expect(req.context == nil)
        #expect(req.recommendation == nil)
        #expect(req.issues.isEmpty)
    }

    /// §6.1.2 merged 2 issues（典型场景）
    @Test func v2_merged_2_issues() throws {
        let json = """
        {
          "request_id": "9c1d8b73-2a4f-4e6c-b5d8-3e7f1a9c2b04",
          "title": "Sieve 检测到 2 个安全问题",
          "severity": "critical",
          "direction": "inbound",
          "disposition": "gui_popup",
          "timeout_seconds": 30,
          "default_on_timeout": "block",
          "allow_remember": false,
          "merged": true,
          "received_at_daemon": "2026-05-02T15:03:11.234Z",
          "source_agent": "claude",
          "origin_chain": [],
          "source_channel": null,
          "explicit_chain_depth": 0,
          "issues": [
            {
              "issue_id": "i-1",
              "rule_id": "IN-CR-05",
              "title": "签名工具调用：signTransaction",
              "severity": "critical",
              "allow_remember": false,
              "context": { "template": "signing_tool_use", "tool_name": "signTransaction", "chain": "Ethereum" },
              "recommendation": { "decision": "deny", "confidence": "high", "reason": "phishing pattern" }
            },
            {
              "issue_id": "i-2",
              "rule_id": "IN-GEN-04",
              "title": "Markdown 图片外链",
              "severity": "high",
              "allow_remember": true,
              "context": { "template": "markdown_exfil", "markdown_snippet": "[x](http://evil.com/img)", "urls": ["http://evil.com/img"] },
              "recommendation": { "decision": "deny", "confidence": "medium", "reason": "external image tracking" }
            }
          ]
        }
        """
        let req = try HipsRequestDecoder.decode(id: "9c1d8b73-2a4f-4e6c-b5d8-3e7f1a9c2b04", paramsData: Data(json.utf8))
        #expect(req.merged == true)
        #expect(req.issues.count == 2)
        #expect(req.severity == .critical)
        #expect(req.allowRemember == false)
        #expect(req.receivedAtDaemon != nil)
        // merged 形式顶层不含 rule_id / context / recommendation
        #expect(req.ruleId == nil)
        #expect(req.context == nil)
        #expect(req.recommendation == nil)
        let i1 = req.issues.first { $0.id == "i-1" }
        let i2 = req.issues.first { $0.id == "i-2" }
        #expect(i1 != nil)
        #expect(i1?.severity == .critical)
        #expect(i1?.allowRemember == false)
        #expect(i2 != nil)
        #expect(i2?.severity == .high)
        #expect(i2?.allowRemember == true)
        #expect(req.hasCriticalIssue == true)
    }

    /// §6.1.2 merged 3 issues + 含 critical（ADR-021 三道防线触发路径）
    @Test func v2_merged_3_issues_with_critical() throws {
        let json = """
        {
          "request_id": "merged-3-crit",
          "title": "Sieve 检测到 3 个安全问题",
          "severity": "critical",
          "direction": "outbound",
          "disposition": "gui_popup",
          "timeout_seconds": 30,
          "default_on_timeout": "block",
          "allow_remember": false,
          "merged": true,
          "received_at_daemon": "2026-05-02T16:00:00.000Z",
          "source_agent": "open_claw",
          "origin_chain": [],
          "source_channel": "main",
          "explicit_chain_depth": 0,
          "issues": [
            {
              "issue_id": "i-1",
              "rule_id": "OUT-07",
              "title": "私钥外传",
              "severity": "critical",
              "allow_remember": false,
              "context": {
                "template": "secret_outbound",
                "secret_kind": "private_key",
                "prefix4": "0x1a",
                "suffix4": "9f3c",
                "length": 64,
                "hash_short": "a1b2c3d4"
              },
              "recommendation": { "decision": "deny", "confidence": "high", "reason": "private key detected in outbound" }
            },
            {
              "issue_id": "i-2",
              "rule_id": "IN-CR-01",
              "title": "地址替换检测",
              "severity": "high",
              "allow_remember": false,
              "context": {
                "template": "address_compare",
                "original_address": "0xAbCd1234567890AbCd1234567890AbCd12345678",
                "substituted_address": "0xAbCd1234567890AbCd1234567890AbCd12345679",
                "chain": "Ethereum",
                "levenshtein": 1
              },
              "recommendation": null
            },
            {
              "issue_id": "i-3",
              "rule_id": "IN-GEN-04",
              "title": "Markdown 外链追踪",
              "severity": "medium",
              "allow_remember": true,
              "context": null,
              "recommendation": null
            }
          ]
        }
        """
        let req = try HipsRequestDecoder.decode(id: "merged-3-crit", paramsData: Data(json.utf8))
        #expect(req.merged == true)
        #expect(req.issues.count == 3)
        #expect(req.severity == .critical)
        #expect(req.allowRemember == false)
        #expect(req.defaultOnTimeout == .block)
        #expect(req.receivedAtDaemon != nil)
        #expect(req.hasCriticalIssue == true)
        // ADR-021 第三道防线：hasCriticalIssue=true 时 GUI 必须禁止"全部允许"按钮
        let i1 = req.issues.first { $0.id == "i-1" }
        #expect(i1?.severity == .critical)
        #expect(i1?.allowRemember == false)
        if case .secretOutbound(let s) = i1?.context {
            #expect(s.secretKind == "private_key")
            #expect(s.prefix4 == "0x1a")
            #expect(s.length == 64)
        } else {
            Issue.record("i-1 expected secret_outbound context")
        }
        let i2 = req.issues.first { $0.id == "i-2" }
        if case .addressCompare(let a) = i2?.context {
            #expect(a.levenshtein == 1)
            #expect(a.chain == "Ethereum")
        } else {
            Issue.record("i-2 expected address_compare context")
        }
        // i-3 null context → generic 兜底
        let i3 = req.issues.first { $0.id == "i-3" }
        #expect(i3?.severity == .medium)
        if case .generic = i3?.context {
            // ok - null context 降级为 generic
        } else {
            Issue.record("i-3 null context should fall back to generic")
        }
    }
}
