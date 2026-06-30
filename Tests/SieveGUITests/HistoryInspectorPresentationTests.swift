import Testing
import Foundation
@testable import SieveGUICore

@Suite("HistoryInspectorPresentation — Inspector 脱敏与字段展示")
struct HistoryInspectorPresentationTests {
    private func makeRow(
        fingerprint: String? = "sha256:abcdef1234567890",
        sessionId: String? = "session-abcdef1234",
        callerPid: Int? = 12345,
        callerExe: String? = "/Applications/Sieve Test/claude",
        evidenceMetaJSON: String? = #"{"len":412,"prefix_hash":"abc123","suffix_hash":"def456","tool_name":"signTransaction","nested":{"request_id":"req-secret","safe":"ok"}}"#
    ) -> AuditEventRow {
        AuditEventRow(
            id: 1024,
            createdAt: Date(timeIntervalSince1970: 1_779_000_000),
            direction: .inbound,
            severity: .critical,
            ruleId: "IN-CR-05",
            disposition: "gui_popup",
            userChoice: "deny",
            fingerprint: fingerprint,
            sessionId: sessionId,
            callerPid: callerPid,
            callerExe: callerExe,
            evidenceMetaJSON: evidenceMetaJSON,
            requestId: "req-001"
        )
    }

    @Test("默认态显示短 fingerprint/session，并只显示 caller_exe basename")
    func locked_summary_masks_sensitive_fields() {
        let presentation = HistoryInspectorPresentation(row: makeRow(), contentUnlocked: false)

        #expect(presentation.fingerprintText == "sha2••••7890")
        #expect(presentation.sessionIdText == "session-…")
        #expect(presentation.callerPidText == "••••••••")
        #expect(presentation.callerExeBasename == "claude")
        #expect(!presentation.callerExeBasename.contains("/Applications"))
    }

    @Test("缺失字段显示空占位，不让 Inspector 行消失")
    func missing_fields_use_empty_placeholder() {
        let presentation = HistoryInspectorPresentation(
            row: makeRow(fingerprint: nil, sessionId: nil, callerPid: nil, callerExe: nil, evidenceMetaJSON: nil),
            contentUnlocked: false
        )

        #expect(presentation.fingerprintText == "—")
        #expect(presentation.sessionIdText == "—")
        #expect(presentation.callerPidText == "—")
        #expect(presentation.callerExeBasename == "—")
        #expect(presentation.evidenceMetaText == "—")
    }

    @Test("默认 evidence_meta 摘要保留安全字段并遮掉敏感字段")
    func locked_evidence_meta_preserves_safe_fields_only() throws {
        let presentation = HistoryInspectorPresentation(row: makeRow(), contentUnlocked: false)
        let data = try #require(presentation.evidenceMetaText.data(using: .utf8))
        let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let nested = try #require(obj["nested"] as? [String: Any])

        #expect(obj["len"] as? Int == 412)
        #expect(obj["tool_name"] as? String == "signTransaction")
        #expect(obj["prefix_hash"] as? String == "••••••••")
        #expect(obj["suffix_hash"] as? String == "••••••••")
        #expect(nested["request_id"] as? String == "••••••••")
        #expect(nested["safe"] as? String == "ok")
        #expect(!presentation.evidenceMetaText.contains("abc123"))
        #expect(!presentation.evidenceMetaText.contains("req-secret"))
    }

    @Test("解锁态显示完整 session/fingerprint/evidence，但 caller_exe 仍不展示完整路径")
    func unlocked_values_show_full_ids_without_full_caller_path() {
        let presentation = HistoryInspectorPresentation(row: makeRow(), contentUnlocked: true)

        #expect(presentation.fingerprintText == "sha256:abcdef1234567890")
        #expect(presentation.sessionIdText == "session-abcdef1234")
        #expect(presentation.callerPidText == "12345")
        #expect(presentation.callerExeBasename == "claude")
        #expect(presentation.evidenceMetaText.contains("abc123"))
        #expect(!presentation.callerExeBasename.contains("/Applications"))
    }
}
