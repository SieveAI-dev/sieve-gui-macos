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
          "disposition": "GuiPopup",
          "timeout_seconds": 120,
          "default_on_timeout": "Block",
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
          "disposition": "GuiPopup",
          "timeout_seconds": 30,
          "default_on_timeout": "Block",
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
          "disposition": "GuiPopup",
          "timeout_seconds": 10,
          "default_on_timeout": "Allow",
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
}
