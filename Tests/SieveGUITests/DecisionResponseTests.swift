import Testing
import Foundation
@testable import SieveGUICore

@Suite("DecisionResponse encoding-layer guard")
struct DecisionResponseTests {
    @Test("allow_remember=false 强制 remember=false（即便 UI 传 true）")
    func encoding_layer_forces_remember_false() {
        let response = DecisionResponse(
            id: "r-1",
            decision: .allow,
            remember: true,                 // UI 端传 true
            contextHint: "test",
            uiPhaseWhenClicked: .blue
        )
        let result = response.resultJSON(allowRemember: false)
        #expect(result["remember"] as? Bool == false)
    }

    @Test("allow_remember=true 时如实传递 remember 值")
    func encoding_layer_passes_through_when_allowed() {
        let response = DecisionResponse(
            id: "r-2",
            decision: .allow,
            remember: true,
            contextHint: nil,
            uiPhaseWhenClicked: .orange
        )
        let result = response.resultJSON(allowRemember: true)
        #expect(result["remember"] as? Bool == true)
    }

    @Test("merged 部分允许：每个 issue 独立强制")
    func merged_per_issue_force() {
        let response = MergedDecisionResponse(id: "m-1", perIssue: [
            .init(issueId: "i-1", decision: .allow, remember: true, contextHint: nil, allowRemember: false),
            .init(issueId: "i-2", decision: .allow, remember: true, contextHint: nil, allowRemember: true),
        ])
        let result = response.resultJSON()
        let arr = result["per_issue"] as? [[String: Any]] ?? []
        #expect(arr[0]["remember"] as? Bool == false)
        #expect(arr[1]["remember"] as? Bool == true)
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
