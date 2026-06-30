import Testing
import Foundation
@testable import SieveGUICore

/// HIPS 三条红线行为测试（SPEC-002）
/// 由于 HipsPopupView 在 Features 层（Package.swift exclude），
/// 这里测试驱动视图逻辑的 Model 层属性，覆盖等价行为断言。
@Suite("HIPS 红线：Phase3 swallow / 锁拒绝 / Remember 不渲染")
struct HipsRedLineTests {

    // MARK: - 辅助

    private func makeRequest(
        timeoutSeconds: Int = 30,
        allowRemember: Bool = true,
        recommendation: Recommendation? = nil,
        severity: Severity = .high,
        ruleId: String? = "OUT-07"
    ) -> HipsRequest {
        HipsRequest(
            id: "req-test",
            requestId: "req-test",
            title: "Test",
            severity: severity,
            direction: .outbound,
            timeoutSeconds: timeoutSeconds,
            defaultOnTimeout: .block,
            allowRemember: allowRemember,
            merged: false,
            receivedAtDaemon: nil,
            ruleId: ruleId,
            context: nil,
            recommendation: recommendation,
            issues: [],
            rawJSON: nil
        )
    }

    // MARK: - 1. Phase3（剩余 ≤20%）swallow 路径

    @Test("Phase3：剩余 20% → currentPhase = .red")
    func phase3_at_20_percent_threshold() {
        #expect(HipsPhase.resolve(remaining: 6, total: 30) == .red)
    }

    @Test("Phase3：剩余 21% → currentPhase = .orange（边界）")
    func phase_just_above_20_percent_is_orange() {
        #expect(HipsPhase.resolve(remaining: 21, total: 100) == .orange)
    }

    @Test("Phase3：timeoutSeconds=0 → currentPhase = .red（防除零）")
    func phase_zero_timeout_is_red() {
        #expect(HipsPhase.resolve(remaining: 30, total: 0) == .red)
    }

    // MARK: - 2. recommendation 缺失或 confidence != .high → 主按钮锁拒绝

    @Test("recommendation = nil → mainActionLocksToDeny = true")
    func nil_recommendation_locks_deny() {
        let req = makeRequest(recommendation: nil)
        #expect(Recommendation.mainActionLocksToDeny(req.recommendation) == true)
    }

    @Test("recommendation confidence = .medium → mainActionLocksToDeny = true")
    func medium_confidence_locks_deny() {
        let rec = Recommendation(decision: .allow, confidence: .medium, reason: nil)
        let req = makeRequest(recommendation: rec)
        #expect(Recommendation.mainActionLocksToDeny(req.recommendation) == true)
    }

    @Test("recommendation confidence = .low → mainActionLocksToDeny = true")
    func low_confidence_locks_deny() {
        let rec = Recommendation(decision: .allow, confidence: .low, reason: nil)
        #expect(Recommendation.mainActionLocksToDeny(rec) == true)
    }

    @Test("recommendation confidence = .high → mainActionLocksToDeny = false（唯一解锁条件）")
    func high_confidence_unlocks() {
        let rec = Recommendation(decision: .allow, confidence: .high, reason: nil)
        #expect(Recommendation.mainActionLocksToDeny(rec) == false)
    }

    // MARK: - 3. allow_remember=false → Remember checkbox 不渲染（第三道防线）

    @Test("allow_remember=false → request.allowRemember = false（不得渲染 checkbox）")
    func allow_remember_false_field_preserved() {
        let req = makeRequest(allowRemember: false)
        // View 层：if request.allowRemember { ... checkbox ... }
        // allowRemember=false 意味着这个 if 为 false，checkbox 不被渲染
        #expect(req.allowRemember == false)
    }

    @Test("allow_remember=false → DecisionResponse 编码层强制 remember=false")
    func encoding_layer_forces_remember_false_when_not_allowed() {
        let req = makeRequest(allowRemember: false)
        let response = DecisionResponse(
            id: req.id,
            decision: .allow,
            remember: true,   // UI 端即便传 true
            contextHint: nil,
            byUser: true,
            uiPhaseWhenClicked: .blue
        )
        // 编码层强制：使用 allowRemember=false 时 resultJSON 中 remember 必须为 false
        let result = response.resultJSON(allowRemember: req.allowRemember)
        #expect(result["remember"] as? Bool == false,
                "allow_remember=false 时，resultJSON 必须强制 remember=false（第三道防线）")
    }

    @Test("allow_remember=true → checkbox 应渲染（allowRemember=true）")
    func allow_remember_true_enables_checkbox() {
        let req = makeRequest(allowRemember: true)
        #expect(req.allowRemember == true)
    }

    @Test("allow_remember=true + user remember=true → resultJSON remember=true")
    func allow_remember_true_passes_through() {
        let response = DecisionResponse(
            id: "r-1",
            decision: .allow,
            remember: true,
            contextHint: nil,
            byUser: true,
            uiPhaseWhenClicked: .blue
        )
        let result = response.resultJSON(allowRemember: true)
        #expect(result["remember"] as? Bool == true)
    }
}
