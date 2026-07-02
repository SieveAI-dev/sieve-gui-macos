import Foundation

/// Critical allow 决策的「人在场」认证门（P0-1）。
///
/// 纵深防御的 GUI 半边：同用户恶意进程即使抢占 `~/.sieve/ipc.sock` 冒充 GUI、
/// 拿到 `request_decision` 合法应答通道，也无法通过生物认证批准 Critical 决策；
/// daemon 端 severity 门禁（挡 headless 通道）是另一层，两层缺一不可。
/// deny 恒不过此门——拒绝是安全方向，不加摩擦。
public enum CriticalAllowGate {
    /// 单 issue：仅「allow + Critical」需要认证。
    public static func requiresAuthentication(decision: Decision, severity: Severity) -> Bool {
        decision == .allow && severity == .critical
    }

    /// merged：per-issue 结果中存在「allow 且该 issue 为 Critical」即需要认证。
    /// 正常路径下 MergedDecisionBuilder 的 fail-safe 已不会产出这种组合中的
    /// allowAll-含-Critical 情形，此处按结果集判定作为编码层保底。
    public static func requiresAuthentication(
        perIssue: [MergedDecisionResponse.PerIssue],
        issues: [HipsIssue]
    ) -> Bool {
        let severityByIssueId = severityIndex(issues)
        return perIssue.contains { $0.decision == .allow && severityByIssueId[$0.issueId] == .critical }
    }

    /// 单 issue 最终决策：需要认证时执行 `authenticate`，失败/取消 → 降级 deny。
    public static func finalDecision(
        requested: Decision,
        severity: Severity,
        authenticate: @Sendable () async -> Bool
    ) async -> Decision {
        guard requiresAuthentication(decision: requested, severity: severity) else { return requested }
        return await authenticate() ? .allow : .deny
    }

    /// merged 最终 per-issue：需要认证时执行 `authenticate`；失败 → 仅把 Critical 的
    /// allow 项降级 deny（remember 一并清零，deny 永不 remember），其余项保持不变。
    public static func finalPerIssue(
        requested: [MergedDecisionResponse.PerIssue],
        issues: [HipsIssue],
        authenticate: @Sendable () async -> Bool
    ) async -> [MergedDecisionResponse.PerIssue] {
        guard requiresAuthentication(perIssue: requested, issues: issues) else { return requested }
        if await authenticate() { return requested }
        return demoteCriticalAllows(requested, issues: issues)
    }

    /// 把 per-issue 中「allow 且 Critical」的项降级为 deny（认证失败路径）。
    static func demoteCriticalAllows(
        _ perIssue: [MergedDecisionResponse.PerIssue],
        issues: [HipsIssue]
    ) -> [MergedDecisionResponse.PerIssue] {
        let severityByIssueId = severityIndex(issues)
        return perIssue.map { p in
            guard p.decision == .allow, severityByIssueId[p.issueId] == .critical else { return p }
            return .init(
                issueId: p.issueId,
                decision: .deny,
                remember: false,
                contextHint: nil,
                allowRemember: p.allowRemember
            )
        }
    }

    /// issue_id → severity 索引；重复 id（daemon 不应发出）取首个，fail-closed 不崩溃。
    private static func severityIndex(_ issues: [HipsIssue]) -> [String: Severity] {
        Dictionary(issues.map { ($0.id, $0.severity) }, uniquingKeysWith: { first, _ in first })
    }
}
