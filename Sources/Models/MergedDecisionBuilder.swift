import Foundation

/// 多 issue 合并模式下用户的整体动作（SPEC-002 §4.8 三按钮）。
public enum MergedAction: Sendable, Equatable {
    case denyAll            // 拒绝全部
    case allowAll           // 全部允许（仅 0 Critical 时合法）
    case allowNonCritical   // 仅允许非 Critical 项（Critical 拒绝）
}

/// 把多 issue + 整体动作翻译为 per-issue 决策（SPEC-002 §4.8 / ipc-protocol §4.1）。
public enum MergedDecisionBuilder {

    /// 是否可渲染「全部允许」按钮：无 Critical 才可（红线 PRD §4.3，禁止含 Critical 时允许全部）。
    public static func canAllowAll(_ issues: [HipsIssue]) -> Bool {
        !issues.contains { $0.severity == .critical }
    }

    /// 非 Critical issue 数量（「仅允许非 Critical 项（N）」按钮文案用）。
    public static func nonCriticalCount(_ issues: [HipsIssue]) -> Int {
        issues.filter { $0.severity != .critical }.count
    }

    /// 按动作为每个 issue 生成决策。
    /// - `rememberByIssueId`：用户在展开 issue 上勾选的 remember（默认空 = 不记住）。
    /// - 红线：`deny` 永不 remember；`allowRemember == false` 的 issue 永不 remember。
    public static func perIssues(
        for issues: [HipsIssue],
        action: MergedAction,
        rememberByIssueId: [String: Bool] = [:]
    ) -> [MergedDecisionResponse.PerIssue] {
        issues.map { issue in
            let decision: Decision
            switch action {
            case .denyAll:
                decision = .deny
            case .allowAll:
                decision = .allow
            case .allowNonCritical:
                decision = issue.severity == .critical ? .deny : .allow
            }
            // remember 仅在「allow + 该 issue 允许记住 + 用户勾选」三者同时成立时为 true
            let remember = decision == .allow
                && issue.allowRemember
                && (rememberByIssueId[issue.id] ?? false)
            return .init(
                issueId: issue.id,
                decision: decision,
                remember: remember,
                contextHint: nil,
                allowRemember: issue.allowRemember
            )
        }
    }
}
