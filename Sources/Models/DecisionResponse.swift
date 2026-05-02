import Foundation

/// 用户对 HIPS 弹窗的回应。编码层强制：`allowRemember == false` → `remember = false`。
public struct DecisionResponse: Sendable {
    public let id: String                  // 与 request_decision id 相同
    public let decision: Decision
    public let remember: Bool
    public let contextHint: String?        // ≤ 200 字符
    public let respondedAt: Date
    public let uiPhaseWhenClicked: HipsPhase

    public init(
        id: String,
        decision: Decision,
        remember: Bool,
        contextHint: String?,
        respondedAt: Date = Date(),
        uiPhaseWhenClicked: HipsPhase
    ) {
        self.id = id
        self.decision = decision
        self.remember = remember
        self.contextHint = contextHint
        self.respondedAt = respondedAt
        self.uiPhaseWhenClicked = uiPhaseWhenClicked
    }

    /// 编码为 JSON-RPC response.result 子对象（不含 jsonrpc/id 包装）
    public func resultJSON(allowRemember: Bool) -> [String: Any] {
        var dict: [String: Any] = [
            "decision": decision.rawValue,
            "remember": allowRemember ? remember : false,   // ← 编码层强制
            "responded_at": Self.iso8601(respondedAt),
            "ui_phase_when_clicked": Self.phaseLabel(uiPhaseWhenClicked)
        ]
        if let hint = contextHint, !hint.isEmpty {
            dict["context_hint"] = String(hint.prefix(200))
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
        case .blue: return "blue"
        case .orange: return "orange"
        case .red: return "red"
        }
    }
}

/// 多 issue 部分允许的回应
public struct MergedDecisionResponse: Sendable {
    public let id: String
    public let perIssue: [PerIssue]
    public let respondedAt: Date

    public struct PerIssue: Sendable {
        public let issueId: String
        public let decision: Decision
        public let remember: Bool
        public let contextHint: String?
        public let allowRemember: Bool   // 用于编码层强制

        public init(issueId: String, decision: Decision, remember: Bool, contextHint: String?, allowRemember: Bool) {
            self.issueId = issueId
            self.decision = decision
            self.remember = remember
            self.contextHint = contextHint
            self.allowRemember = allowRemember
        }
    }

    public init(id: String, perIssue: [PerIssue], respondedAt: Date = Date()) {
        self.id = id
        self.perIssue = perIssue
        self.respondedAt = respondedAt
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
                "remember": p.allowRemember ? p.remember : false  // ← 强制
            ]
            if let h = p.contextHint, !h.isEmpty {
                d["context_hint"] = String(h.prefix(200))
            }
            return d
        }
        return [
            "merged_decision": mergedDecisionLabel,
            "per_issue": arr,
            "responded_at": DecisionResponse.iso8601(respondedAt)
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
        case .userCanceledViaWindowClose: return -32000
        case .guiRenderFailed: return -32001
        case .guiShutdownDuringDecision: return -32002
        }
    }

    public var message: String {
        switch self {
        case .userCanceledViaWindowClose: return "user_canceled_via_window_close"
        case .guiRenderFailed: return "gui_render_failed"
        case .guiShutdownDuringDecision: return "gui_shutdown_during_decision"
        }
    }
}
