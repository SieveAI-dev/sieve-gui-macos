import Foundation
import Testing
@testable import SieveGUICore

@Suite("DecisionResponse encoding-layer guard")
struct DecisionResponseTests {
    @Test("allow_remember=false 强制 remember=false（即便 UI 传 true）")
    func encoding_layer_forces_remember_false() {
        let response = DecisionResponse(
            id: "r-1",
            decision: .allow,
            remember: true, // UI 端传 true
            contextHint: "test",
            byUser: true,
            uiPhaseWhenClicked: .blue
        )
        let result = wireJSONObject(response.wire(allowRemember: false))
        #expect(result["remember"] as? Bool == false)
        #expect(result["context_hint"] is NSNull)
    }

    @Test("allow_remember=true 时如实传递 remember 值")
    func encoding_layer_passes_through_when_allowed() {
        let response = DecisionResponse(
            id: "r-2",
            decision: .allow,
            remember: true,
            contextHint: nil,
            byUser: true,
            uiPhaseWhenClicked: .orange
        )
        let result = wireJSONObject(response.wire(allowRemember: true))
        #expect(result["remember"] as? Bool == true)
    }

    @Test("context_hint 只在 allow + remember + allow_remember=true 时保留")
    func context_hint_requires_allow_and_remember() {
        let denied = DecisionResponse(
            id: "r-deny",
            decision: .deny,
            remember: true,
            contextHint: "keep?",
            byUser: true,
            uiPhaseWhenClicked: .blue
        )
        #expect(wireJSONObject(denied.wire(allowRemember: true))["context_hint"] is NSNull)

        let allowedNotRemembered = DecisionResponse(
            id: "r-allow-no-remember",
            decision: .allow,
            remember: false,
            contextHint: "keep?",
            byUser: true,
            uiPhaseWhenClicked: .blue
        )
        #expect(wireJSONObject(allowedNotRemembered.wire(allowRemember: true))["context_hint"] is NSNull)

        let allowedRemembered = DecisionResponse(
            id: "r-allow-remember",
            decision: .allow,
            remember: true,
            contextHint: "keep",
            byUser: true,
            uiPhaseWhenClicked: .blue
        )
        #expect(wireJSONObject(allowedRemembered.wire(allowRemember: true))["context_hint"] as? String == "keep")
    }

    @Test("merged 部分允许：每个 issue 独立强制")
    func merged_per_issue_force() {
        let response = MergedDecisionResponse(id: "m-1", perIssue: [
            .init(issueId: "i-1", decision: .allow, remember: true, contextHint: nil, allowRemember: false),
            .init(issueId: "i-2", decision: .allow, remember: true, contextHint: nil, allowRemember: true)
        ], byUser: true)
        let result = wireJSONObject(response.wire())
        let arr = result["per_issue"] as? [[String: Any]] ?? []
        #expect(arr[0]["remember"] as? Bool == false)
        #expect(arr[1]["remember"] as? Bool == true)
    }

    // MARK: - SPEC-005 §6.2.1 required 字段覆盖

    @Test("wire 包含 request_id / decided_at / by_user（byUser=true 场景）")
    func result_contains_required_fields_by_user_true() {
        let fixedDate = Date(timeIntervalSince1970: 1_746_000_000)
        let response = DecisionResponse(
            id: "req-abc",
            decision: .deny,
            remember: false,
            contextHint: nil,
            decidedAt: fixedDate,
            byUser: true,
            uiPhaseWhenClicked: .orange
        )
        let result = wireJSONObject(response.wire(allowRemember: true))

        #expect(result["request_id"] as? String == "req-abc")
        #expect(result["by_user"] as? Bool == true)
        let decidedAt = result["decided_at"] as? String
        #expect(decidedAt != nil)
        #expect(decidedAt?.contains("2025") == true) // 2025-04-30 左右
    }

    @Test("wire 包含 by_user=false（超时回退场景）")
    func result_contains_required_fields_by_user_false() {
        let response = DecisionResponse(
            id: "req-timeout",
            decision: .deny,
            remember: false,
            contextHint: nil,
            byUser: false, // 超时/失联 auto-deny
            uiPhaseWhenClicked: .red
        )
        let result = wireJSONObject(response.wire(allowRemember: false))

        #expect(result["request_id"] as? String == "req-timeout")
        #expect(result["by_user"] as? Bool == false)
        #expect(result["decided_at"] as? String != nil)
    }

    @Test("wire 不含 responded_at（防 regression）")
    func result_does_not_contain_responded_at() {
        let response = DecisionResponse(
            id: "r-regression",
            decision: .allow,
            remember: false,
            contextHint: nil,
            byUser: true,
            uiPhaseWhenClicked: .blue
        )
        let result = wireJSONObject(response.wire(allowRemember: true))
        #expect(result["responded_at"] == nil)
    }

    @Test("MergedDecisionResponse wire 包含 request_id / decided_at / by_user")
    func merged_result_contains_required_fields() {
        let fixedDate = Date(timeIntervalSince1970: 1_746_000_000)
        let response = MergedDecisionResponse(
            id: "merged-req-1",
            perIssue: [
                .init(issueId: "i-1", decision: .deny, remember: false, contextHint: nil, allowRemember: false)
            ],
            decidedAt: fixedDate,
            byUser: false // 超时场景
        )
        let result = wireJSONObject(response.wire())

        #expect(result["request_id"] as? String == "merged-req-1")
        #expect(result["by_user"] as? Bool == false)
        #expect(result["decided_at"] as? String != nil)
        #expect(result["responded_at"] == nil)
    }
}

@Suite("Recommendation main-action lock")
struct RecommendationLockTests {
    @Test func nil_recommendation_locks_to_deny() {
        #expect(Recommendation.mainActionLocksToDeny(nil))
    }

    @Test func medium_confidence_locks_to_deny() {
        let rec = Recommendation(decision: .allow, confidence: .medium, reason: nil)
        #expect(Recommendation.mainActionLocksToDeny(rec))
    }

    @Test func high_confidence_does_not_lock() {
        let rec = Recommendation(decision: .allow, confidence: .high, reason: nil)
        #expect(!Recommendation.mainActionLocksToDeny(rec))
    }
}
