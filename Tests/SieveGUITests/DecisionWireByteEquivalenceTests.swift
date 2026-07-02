import Foundation
import Testing
@testable import SieveGUICore

/// P2-1 硬约束：决策响应 Codable 化后 wire 字节必须与旧 [String: Any] 手拼逐字节一致。
/// 本套件内联复刻改造前的手拼逻辑（NSNull 显式 null / per-issue 省略键 / 强制 remember /
/// 200 scalar 截断），对代表性载荷比对 IPCOutbound 编码的完整帧。
@Suite("决策 wire 字节等价（Codable 化 vs 旧手拼）")
struct DecisionWireByteEquivalenceTests {
    // MARK: - 改造前手拼逻辑的忠实复刻（仅测试用）

    private func legacySingleResultJSON(_ r: DecisionResponse, allowRemember: Bool) -> [String: Any] {
        var dict: [String: Any] = [
            "request_id": r.id,
            "decision": r.decision.rawValue,
            "remember": allowRemember ? r.remember : false,
            "decided_at": DecisionResponse.iso8601(r.decidedAt),
            "by_user": r.byUser,
            "ui_phase_when_clicked": DecisionResponse.phaseLabel(r.uiPhaseWhenClicked)
        ]
        let maySendContextHint = r.decision == .allow && allowRemember && r.remember
        if maySendContextHint, let hint = r.contextHint, !hint.isEmpty {
            let trimmed = hint.unicodeScalars.count > 200
                ? String(String.UnicodeScalarView(hint.unicodeScalars.prefix(200)))
                : hint
            dict["context_hint"] = trimmed
        } else {
            dict["context_hint"] = NSNull()
        }
        return dict
    }

    private func legacyMergedResultJSON(_ m: MergedDecisionResponse) -> [String: Any] {
        let arr: [[String: Any]] = m.perIssue.map { p in
            var d: [String: Any] = [
                "issue_id": p.issueId,
                "decision": p.decision.rawValue,
                "remember": p.allowRemember ? p.remember : false
            ]
            let maySendContextHint = p.decision == .allow && p.allowRemember && p.remember
            if maySendContextHint, let h = p.contextHint, !h.isEmpty {
                let trimmed = h.unicodeScalars.count > 200
                    ? String(String.UnicodeScalarView(h.unicodeScalars.prefix(200)))
                    : h
                d["context_hint"] = trimmed
            }
            return d
        }
        return [
            "request_id": m.id,
            "merged_decision": m.mergedDecisionLabel,
            "per_issue": arr,
            "decided_at": DecisionResponse.iso8601(m.decidedAt),
            "by_user": m.byUser
        ]
    }

    private func legacyFrame(id: String, result: [String: Any]) -> Data {
        IPCOutbound.encodeLine(["jsonrpc": "2.0", "id": id, "result": result])
    }

    // MARK: - 单 issue

    @Test("单 issue：allow + remember + hint（context_hint 有值）")
    func single_allow_remember_hint_bytes_identical() {
        let r = DecisionResponse(
            id: "r-1", decision: .allow, remember: true, contextHint: "备注 hint",
            decidedAt: Date(timeIntervalSince1970: 1_746_000_000.123), byUser: true, uiPhaseWhenClicked: .blue
        )
        let new = IPCOutbound.response(id: r.id, result: DecisionWire.single(r.wire(allowRemember: true)))
        let old = legacyFrame(id: r.id, result: legacySingleResultJSON(r, allowRemember: true))
        #expect(new == old)
    }

    @Test("单 issue：deny（context_hint 显式 null）")
    func single_deny_bytes_identical() {
        let r = DecisionResponse(
            id: "r-2", decision: .deny, remember: false, contextHint: "会被丢弃",
            decidedAt: Date(timeIntervalSince1970: 1_750_000_000), byUser: true, uiPhaseWhenClicked: .red
        )
        let new = IPCOutbound.response(id: r.id, result: DecisionWire.single(r.wire(allowRemember: true)))
        let old = legacyFrame(id: r.id, result: legacySingleResultJSON(r, allowRemember: true))
        #expect(new == old)
    }

    @Test("单 issue：allowRemember=false 强制 remember=false + 超时 by_user=false")
    func single_forced_remember_bytes_identical() {
        let r = DecisionResponse(
            id: "r-3", decision: .allow, remember: true, contextHint: nil,
            decidedAt: Date(timeIntervalSince1970: 1_751_234_567.891), byUser: false, uiPhaseWhenClicked: .orange
        )
        let new = IPCOutbound.response(id: r.id, result: DecisionWire.single(r.wire(allowRemember: false)))
        let old = legacyFrame(id: r.id, result: legacySingleResultJSON(r, allowRemember: false))
        #expect(new == old)
    }

    @Test("单 issue：超长 hint 截断到 200 scalar")
    func single_truncated_hint_bytes_identical() {
        let r = DecisionResponse(
            id: "r-4", decision: .allow, remember: true, contextHint: String(repeating: "字", count: 250),
            decidedAt: Date(timeIntervalSince1970: 1_752_000_000), byUser: true, uiPhaseWhenClicked: .blue
        )
        let new = IPCOutbound.response(id: r.id, result: DecisionWire.single(r.wire(allowRemember: true)))
        let old = legacyFrame(id: r.id, result: legacySingleResultJSON(r, allowRemember: true))
        #expect(new == old)
    }

    // MARK: - merged

    @Test("merged：partial（含 hint 项 + 无 hint 项 + 强制 remember 项）")
    func merged_partial_bytes_identical() {
        let m = MergedDecisionResponse(
            id: "m-1",
            perIssue: [
                .init(issueId: "i-1", decision: .allow, remember: true, contextHint: "记住原因", allowRemember: true),
                .init(issueId: "i-2", decision: .deny, remember: false, contextHint: nil, allowRemember: true),
                .init(issueId: "i-3", decision: .allow, remember: true, contextHint: nil, allowRemember: false)
            ],
            decidedAt: Date(timeIntervalSince1970: 1_753_000_000.5),
            byUser: true
        )
        let new = IPCOutbound.response(id: m.id, result: DecisionWire.merged(m.wire()))
        let old = legacyFrame(id: m.id, result: legacyMergedResultJSON(m))
        #expect(new == old)
    }

    @Test("merged：all_deny 超时（by_user=false）")
    func merged_all_deny_bytes_identical() {
        let m = MergedDecisionResponse(
            id: "m-2",
            perIssue: [
                .init(issueId: "i-1", decision: .deny, remember: false, contextHint: nil, allowRemember: false),
                .init(issueId: "i-2", decision: .deny, remember: false, contextHint: nil, allowRemember: true)
            ],
            decidedAt: Date(timeIntervalSince1970: 1_754_000_000),
            byUser: false
        )
        let new = IPCOutbound.response(id: m.id, result: DecisionWire.merged(m.wire()))
        let old = legacyFrame(id: m.id, result: legacyMergedResultJSON(m))
        #expect(new == old)
    }
}
