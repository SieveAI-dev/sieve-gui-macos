import Foundation
import Testing
@testable import SieveGUICore

/// P0-1（CLI spec F1-GUI）：Critical allow 的「人在场」认证门。
/// HipsPanelManager 在 Features 层（swift test 编不到），此处锚定其调用的 Core 门函数。
@Suite("CriticalAllowGate：Critical allow 必须过认证，失败降级 deny")
struct CriticalAllowGateTests {
    // MARK: - 辅助

    private func makeIssue(id: String, severity: Severity, allowRemember: Bool = true) -> HipsIssue {
        HipsIssue(
            id: id,
            ruleId: "IN-CR-01",
            title: "issue-\(id)",
            severity: severity,
            allowRemember: allowRemember,
            context: .generic(.init(payload: AnyCodable(rawData: Data()))),
            recommendation: nil
        )
    }

    // MARK: - 单 issue：是否需要认证

    @Test("allow + critical → 需要认证；其余组合不需要")
    func single_requires_authentication_matrix() {
        #expect(CriticalAllowGate.requiresAuthentication(decision: .allow, severity: .critical))
        #expect(!CriticalAllowGate.requiresAuthentication(decision: .deny, severity: .critical))
        #expect(!CriticalAllowGate.requiresAuthentication(decision: .allow, severity: .high))
        #expect(!CriticalAllowGate.requiresAuthentication(decision: .allow, severity: .medium))
        #expect(!CriticalAllowGate.requiresAuthentication(decision: .allow, severity: .low))
        #expect(!CriticalAllowGate.requiresAuthentication(decision: .deny, severity: .high))
    }

    // MARK: - 单 issue：认证结果决定最终决策

    @Test("Critical allow + 认证成功 → allow 正常放行")
    func single_auth_success_allows() async {
        let final = await CriticalAllowGate.finalDecision(
            requested: .allow, severity: .critical, authenticate: { true }
        )
        #expect(final == .allow)
    }

    @Test("Critical allow + 认证失败/取消 → 降级 deny，不发 allow")
    func single_auth_failure_degrades_to_deny() async {
        let final = await CriticalAllowGate.finalDecision(
            requested: .allow, severity: .critical, authenticate: { false }
        )
        #expect(final == .deny)
    }

    @Test("非 Critical allow → 不触发认证器（deny 同理，拒绝不加摩擦）")
    func non_critical_never_invokes_authenticator() async {
        final class InvocationFlag: @unchecked Sendable {
            var invoked = false
        }
        let flag = InvocationFlag()
        let allowFinal = await CriticalAllowGate.finalDecision(
            requested: .allow, severity: .high, authenticate: { flag.invoked = true; return false }
        )
        let denyFinal = await CriticalAllowGate.finalDecision(
            requested: .deny, severity: .critical, authenticate: { flag.invoked = true; return false }
        )
        #expect(allowFinal == .allow)
        #expect(denyFinal == .deny)
        #expect(!flag.invoked)
    }

    // MARK: - merged：是否需要认证

    @Test("allowNonCritical：Critical 项本就 deny → 不需要认证")
    func merged_allow_non_critical_requires_no_auth() {
        let issues = [makeIssue(id: "i1", severity: .critical), makeIssue(id: "i2", severity: .high)]
        let perIssue = MergedDecisionBuilder.perIssues(for: issues, action: .allowNonCritical)
        #expect(!CriticalAllowGate.requiresAuthentication(perIssue: perIssue, issues: issues))
    }

    @Test("allowAll（无 Critical）→ 不需要认证")
    func merged_allow_all_without_critical_requires_no_auth() {
        let issues = [makeIssue(id: "i1", severity: .high), makeIssue(id: "i2", severity: .low)]
        let perIssue = MergedDecisionBuilder.perIssues(for: issues, action: .allowAll)
        #expect(!CriticalAllowGate.requiresAuthentication(perIssue: perIssue, issues: issues))
    }

    @Test("per-issue 中出现 Critical 的 allow（编码层保底场景）→ 需要认证")
    func merged_critical_allow_requires_auth() {
        let issues = [makeIssue(id: "i1", severity: .critical), makeIssue(id: "i2", severity: .high)]
        let crafted: [MergedDecisionResponse.PerIssue] = [
            .init(issueId: "i1", decision: .allow, remember: false, contextHint: nil, allowRemember: true),
            .init(issueId: "i2", decision: .allow, remember: false, contextHint: nil, allowRemember: true)
        ]
        #expect(CriticalAllowGate.requiresAuthentication(perIssue: crafted, issues: issues))
    }

    // MARK: - merged：认证失败仅降级 Critical 的 allow

    @Test("merged 认证失败 → Critical allow 降 deny + remember 清零，其余项保持")
    func merged_auth_failure_demotes_only_critical_allows() async {
        let issues = [
            makeIssue(id: "i1", severity: .critical),
            makeIssue(id: "i2", severity: .high),
            makeIssue(id: "i3", severity: .critical)
        ]
        let crafted: [MergedDecisionResponse.PerIssue] = [
            .init(issueId: "i1", decision: .allow, remember: true, contextHint: "hint", allowRemember: true),
            .init(issueId: "i2", decision: .allow, remember: true, contextHint: nil, allowRemember: true),
            .init(issueId: "i3", decision: .deny, remember: false, contextHint: nil, allowRemember: false)
        ]
        let final = await CriticalAllowGate.finalPerIssue(
            requested: crafted, issues: issues, authenticate: { false }
        )
        // i1：Critical allow → 降 deny，remember/contextHint 清零
        #expect(final[0].decision == .deny)
        #expect(final[0].remember == false)
        #expect(final[0].contextHint == nil)
        // i2：非 Critical allow → 原样保持
        #expect(final[1].decision == .allow)
        #expect(final[1].remember == true)
        // i3：Critical deny → 原样保持
        #expect(final[2].decision == .deny)
    }

    @Test("merged 认证成功 → per-issue 原样放行")
    func merged_auth_success_keeps_decisions() async {
        let issues = [makeIssue(id: "i1", severity: .critical)]
        let crafted: [MergedDecisionResponse.PerIssue] = [
            .init(issueId: "i1", decision: .allow, remember: false, contextHint: nil, allowRemember: true)
        ]
        let final = await CriticalAllowGate.finalPerIssue(
            requested: crafted, issues: issues, authenticate: { true }
        )
        #expect(final[0].decision == .allow)
    }
}
