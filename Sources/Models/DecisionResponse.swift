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

    /// 编码为 JSON-RPC response.result 子对象（不含 jsonrpc/id 包装）。
    /// P2-1：Codable 结构体（禁 [String:Any] 透传，SPEC-008 §7），wire 字节与旧手拼一致
    /// （等价测试锚定）。
    public func wire(allowRemember: Bool) -> DecisionResultWire {
        // SPEC-002 §4.6：context_hint 只属于“允许并记住”路径；未 remember 或 deny 时不外带。
        let maySendContextHint = decision == .allow && allowRemember && remember
        // SPEC-005 §1.3: context_hint ≤ 200 Unicode scalars；编码层按 scalar 计数截断（最终防线）
        var hint: String?
        if maySendContextHint, let raw = contextHint, !raw.isEmpty {
            hint = raw.unicodeScalars.count > 200
                ? String(String.UnicodeScalarView(raw.unicodeScalars.prefix(200)))
                : raw
        }
        return DecisionResultWire(
            requestId: id,
            decision: decision.rawValue,
            remember: allowRemember ? remember : false, // ← 编码层强制
            decidedAt: Self.iso8601(decidedAt),
            byUser: byUser,
            uiPhaseWhenClicked: Self.phaseLabel(uiPhaseWhenClicked),
            contextHint: hint
        )
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

    /// P2-1：Codable 结构体 wire 编码（禁 [String:Any] 透传，SPEC-008 §7）。
    public func wire() -> MergedDecisionResultWire {
        let issues = perIssue.map { p in
            // SPEC-002 §4.6：context_hint 只属于“允许并记住”路径；未 remember 或 deny 时不外带。
            let maySendContextHint = p.decision == .allow && p.allowRemember && p.remember
            // SPEC-005 §1.3: context_hint ≤ 200 Unicode scalars
            var hint: String?
            if maySendContextHint, let raw = p.contextHint, !raw.isEmpty {
                hint = raw.unicodeScalars.count > 200
                    ? String(String.UnicodeScalarView(raw.unicodeScalars.prefix(200)))
                    : raw
            }
            return MergedDecisionResultWire.PerIssueWire(
                issueId: p.issueId,
                decision: p.decision.rawValue,
                remember: p.allowRemember ? p.remember : false, // ← 强制
                contextHint: hint
            )
        }
        return MergedDecisionResultWire(
            requestId: id,
            mergedDecision: mergedDecisionLabel,
            perIssue: issues,
            decidedAt: DecisionResponse.iso8601(decidedAt),
            byUser: byUser
        )
    }
}

// MARK: - Wire 编码（P2-1）

/// 单 issue 决策的 result 载荷。字段集与既有 wire 输出严格一致：
/// `context_hint` 无值时编码为显式 null（键恒在），与旧行为逐字节等价。
public struct DecisionResultWire: Encodable, Sendable {
    public let requestId: String
    public let decision: String
    public let remember: Bool
    public let decidedAt: String
    public let byUser: Bool
    public let uiPhaseWhenClicked: String
    public let contextHint: String?

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case decision
        case remember
        case decidedAt = "decided_at"
        case byUser = "by_user"
        case uiPhaseWhenClicked = "ui_phase_when_clicked"
        case contextHint = "context_hint"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(decision, forKey: .decision)
        try c.encode(remember, forKey: .remember)
        try c.encode(decidedAt, forKey: .decidedAt)
        try c.encode(byUser, forKey: .byUser)
        try c.encode(uiPhaseWhenClicked, forKey: .uiPhaseWhenClicked)
        if let contextHint {
            try c.encode(contextHint, forKey: .contextHint)
        } else {
            try c.encodeNil(forKey: .contextHint) // 显式 null，键恒在（与旧手拼一致）
        }
    }
}

/// merged 决策的 result 载荷。per_issue 的 `context_hint` 无值时省略键（与旧行为一致）。
public struct MergedDecisionResultWire: Encodable, Sendable {
    public struct PerIssueWire: Encodable, Sendable {
        public let issueId: String
        public let decision: String
        public let remember: Bool
        public let contextHint: String? // 合成 Encodable：nil → 省略键

        enum CodingKeys: String, CodingKey {
            case issueId = "issue_id"
            case decision
            case remember
            case contextHint = "context_hint"
        }
    }

    public let requestId: String
    public let mergedDecision: String
    public let perIssue: [PerIssueWire]
    public let decidedAt: String
    public let byUser: Bool

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case mergedDecision = "merged_decision"
        case perIssue = "per_issue"
        case decidedAt = "decided_at"
        case byUser = "by_user"
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
