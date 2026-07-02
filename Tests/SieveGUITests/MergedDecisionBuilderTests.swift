import Foundation
import Testing
@testable import SieveGUICore

/// SPEC-002 §4.8：多 issue 合并模式下，整体动作（拒绝全部 / 全部允许 / 仅允许非 Critical）
/// → per-issue 决策的翻译逻辑。纯逻辑核心库类型。
@Suite("MergedDecisionBuilder — 多 issue 部分允许决策生成")
struct MergedDecisionBuilderTests {
    private func issue(_ id: String, _ severity: Severity, allowRemember: Bool = true) -> HipsIssue {
        HipsIssue(
            id: id, ruleId: "RULE-\(id)", title: id, severity: severity,
            allowRemember: allowRemember,
            context: .generic(.init(payload: AnyCodable(rawData: Data()))),
            recommendation: nil
        )
    }

    @Test("denyAll：所有 issue 决策为 deny")
    func deny_all() {
        let issues = [issue("a", .critical), issue("b", .high)]
        let r = MergedDecisionBuilder.perIssues(for: issues, action: .denyAll)
        #expect(r.map(\.decision) == [.deny, .deny])
    }

    @Test("allowAll：所有 issue 决策为 allow")
    func allow_all() {
        let issues = [issue("a", .high), issue("b", .medium)]
        let r = MergedDecisionBuilder.perIssues(for: issues, action: .allowAll)
        #expect(r.map(\.decision) == [.allow, .allow])
    }

    @Test("红线：含 Critical 时即便误传 allowAll，也不得允许 Critical")
    func allow_all_with_critical_degrades_to_partial() {
        let issues = [issue("a", .critical), issue("b", .high)]
        let r = MergedDecisionBuilder.perIssues(for: issues, action: .allowAll)
        #expect(r.first { $0.issueId == "a" }?.decision == .deny)
        #expect(r.first { $0.issueId == "b" }?.decision == .allow)

        let response = MergedDecisionResponse(id: "merged-critical", perIssue: r, byUser: true)
        #expect(response.mergedDecisionLabel == "partial")
    }

    @Test("allowNonCritical：Critical 拒绝、非 Critical 允许")
    func allow_non_critical() {
        let issues = [issue("a", .critical), issue("b", .high), issue("c", .low)]
        let r = MergedDecisionBuilder.perIssues(for: issues, action: .allowNonCritical)
        #expect(r.first { $0.issueId == "a" }?.decision == .deny)
        #expect(r.first { $0.issueId == "b" }?.decision == .allow)
        #expect(r.first { $0.issueId == "c" }?.decision == .allow)
    }

    @Test("canAllowAll：含 Critical → false，无 Critical → true")
    func can_allow_all() {
        #expect(MergedDecisionBuilder.canAllowAll([issue("a", .critical), issue("b", .high)]) == false)
        #expect(MergedDecisionBuilder.canAllowAll([issue("a", .high), issue("b", .low)]) == true)
    }

    @Test("nonCriticalCount：正确计数非 Critical")
    func non_critical_count() {
        let issues = [issue("a", .critical), issue("b", .high), issue("c", .critical), issue("d", .medium)]
        #expect(MergedDecisionBuilder.nonCriticalCount(issues) == 2)
    }

    @Test("红线：deny 永不 remember；allowRemember=false 的 allow 也不 remember")
    func remember_rules() {
        let issues = [
            issue("deny-me", .critical, allowRemember: true),
            issue("no-remember", .high, allowRemember: false),
            issue("ok", .low, allowRemember: true)
        ]
        let r = MergedDecisionBuilder.perIssues(
            for: issues, action: .allowNonCritical,
            rememberByIssueId: ["deny-me": true, "no-remember": true, "ok": true]
        )
        #expect(r.first { $0.issueId == "deny-me" }?.remember == false)
        #expect(r.first { $0.issueId == "no-remember" }?.remember == false)
        #expect(r.first { $0.issueId == "ok" }?.remember == true)
    }
}
