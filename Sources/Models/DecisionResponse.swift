import Foundation

/// 用户对 HIPS 弹窗的回应。编码层强制：`allowRemember == false` → `remember = false`。
public struct DecisionResponse: Sendable {
    public let id: String // 与 request_decision id 相同（= JSON-RPC id）
    public let decision: Decision
    public let remember: Bool
    public let contextHint: String? // ≤ 200 字符
    public let decidedAt: Date // GUI 端时钟，SPEC-005 §6.2.1 required
    public let byUser: Bool // true=用户主动操作；false=超时/失联回退
    public let uiPhaseWhenClicked: HipsPhase

    public init(
        id: String,
        decision: Decision,
        remember: Bool,
        contextHint: String?,
        decidedAt: Date = Date(),
        byUser: Bool,
        uiPhaseWhenClicked: HipsPhase
    ) {
        self.id = id
        self.decision = decision
        self.remember = remember
        self.contextHint = contextHint
        self.decidedAt = decidedAt
        self.byUser = byUser
        self.uiPhaseWhenClicked = uiPhaseWhenClicked
    }

    /// 编码为 JSON-RPC response.result 子对象（不含 jsonrpc/id 包装）
    public func resultJSON(allowRemember: Bool) -> [String: Any] {
        var dict: [String: Any] = [
            "request_id": id,
            "decision": decision.rawValue,
            "remember": allowRemember ? remember : false, // ← 编码层强制
            "decided_at": Self.iso8601(decidedAt),
            "by_user": byUser,
            "ui_phase_when_clicked": Self.phaseLabel(uiPhaseWhenClicked)
        ]
        // SPEC-002 §4.6：context_hint 只属于“允许并记住”路径；未 remember 或 deny 时不外带。
        let maySendContextHint = decision == .allow && allowRemember && remember
        // SPEC-005 §1.3: context_hint ≤ 200 Unicode scalars；编码层按 scalar 计数截断（最终防线）
        if maySendContextHint, let hint = contextHint, !hint.isEmpty {
            let trimmed = hint.unicodeScalars.count > 200
                ? String(String.UnicodeScalarView(hint.unicodeScalars.prefix(200)))
                : hint
            dict["context_hint"] = trimmed
        } else {
            dict["context_hint"] = NSNull()
        }
        return dict
    }

    static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func phaseLabel(_ phase: HipsPhase) -> String {
        switch phase {
        case .blue: "blue"
        case .orange: "orange"
        case .red: "red"
        }
    }
}

/// 多 issue 部分允许的回应
public struct MergedDecisionResponse: Sendable {
    public let id: String
    public let perIssue: [PerIssue]
    public let decidedAt: Date // GUI 端时钟，SPEC-005 §6.2.1 required
    public let byUser: Bool // true=用户主动操作；false=超时/失联回退

    public struct PerIssue: Sendable {
        public let issueId: String
        public let decision: Decision
        public let remember: Bool
        public let contextHint: String?
        public let allowRemember: Bool // 用于编码层强制

        public init(issueId: String, decision: Decision, remember: Bool, contextHint: String?, allowRemember: Bool) {
            self.issueId = issueId
            self.decision = decision
            self.remember = remember
            self.contextHint = contextHint
            self.allowRemember = allowRemember
        }
    }

    public init(id: String, perIssue: [PerIssue], decidedAt: Date = Date(), byUser: Bool) {
        self.id = id
        self.perIssue = perIssue
        self.decidedAt = decidedAt
        self.byUser = byUser
    }

    public var mergedDecisionLabel: String {
        let allDeny = perIssue.allSatisfy { $0.decision == .deny }
        let allAllow = perIssue.allSatisfy { $0.decision == .allow }
        if allDeny { return "all_deny" }
        if allAllow { return "all_allow" }
        return "partial"
    }

    public func resultJSON() -> [String: Any] {
        let arr: [[String: Any]] = perIssue.map { p in
            var d: [String: Any] = [
                "issue_id": p.issueId,
                "decision": p.decision.rawValue,
                "remember": p.allowRemember ? p.remember : false // ← 强制
            ]
            // SPEC-002 §4.6：context_hint 只属于“允许并记住”路径；未 remember 或 deny 时不外带。
            let maySendContextHint = p.decision == .allow && p.allowRemember && p.remember
            // SPEC-005 §1.3: context_hint ≤ 200 Unicode scalars
            if maySendContextHint, let h = p.contextHint, !h.isEmpty {
                let trimmed = h.unicodeScalars.count > 200
                    ? String(String.UnicodeScalarView(h.unicodeScalars.prefix(200)))
                    : h
                d["context_hint"] = trimmed
            }
            return d
        }
        return [
            "request_id": id,
            "merged_decision": mergedDecisionLabel,
            "per_issue": arr,
            "decided_at": DecisionResponse.iso8601(decidedAt),
            "by_user": byUser
        ]
    }
}

/// GUI 主动汇报的错误（关闭窗口 / 渲染失败 / 进程退出）
public enum DecisionError: Sendable {
    case userCanceledViaWindowClose
    case guiRenderFailed
    case guiShutdownDuringDecision

    public var code: Int {
        switch self {
        case .userCanceledViaWindowClose: -32100
        case .guiRenderFailed: -32101
        case .guiShutdownDuringDecision: -32102
        }
    }

    public var message: String {
        switch self {
        case .userCanceledViaWindowClose: "user_canceled_via_window_close"
        case .guiRenderFailed: "gui_render_failed"
        case .guiShutdownDuringDecision: "gui_shutdown_during_decision"
        }
    }
}
