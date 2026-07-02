import Foundation

/// 单 issue 或合并 issue 的 HIPS 决策请求。
/// `rawJSON` 在弹窗关闭后必须主动 `clearRawJSON()` 置空。
public final class HipsRequest: Identifiable, @unchecked Sendable {
    public let id: String
    public let requestId: String
    public let title: String
    public let severity: Severity
    public let direction: Direction
    public let timeoutSeconds: Int
    public let defaultOnTimeout: DefaultOnTimeout
    public let allowRemember: Bool
    public let merged: Bool
    public let receivedAtDaemon: Date?

    /// 单 issue 形式才有
    public let ruleId: String?
    public let context: HipsContext?
    public let recommendation: Recommendation?

    /// 合并形式才有
    public let issues: [HipsIssue]

    public private(set) var rawJSON: Data?
    public let receivedAtGUI: Date

    public init(
        id: String,
        requestId: String,
        title: String,
        severity: Severity,
        direction: Direction,
        timeoutSeconds: Int,
        defaultOnTimeout: DefaultOnTimeout,
        allowRemember: Bool,
        merged: Bool,
        receivedAtDaemon: Date?,
        ruleId: String?,
        context: HipsContext?,
        recommendation: Recommendation?,
        issues: [HipsIssue],
        rawJSON: Data?
    ) {
        self.id = id
        self.requestId = requestId
        self.title = title
        self.severity = severity
        self.direction = direction
        self.timeoutSeconds = timeoutSeconds
        self.defaultOnTimeout = defaultOnTimeout
        self.allowRemember = allowRemember
        self.merged = merged
        self.receivedAtDaemon = receivedAtDaemon
        self.ruleId = ruleId
        self.context = context
        self.recommendation = recommendation
        self.issues = issues
        self.rawJSON = rawJSON
        receivedAtGUI = Date()
    }

    /// 关闭后必须调用：rawJSON 内可能含 evidence，不允许跨弹窗存留
    public func clearRawJSON() {
        rawJSON = nil
    }

    /// 多 issue 中是否含 critical（决定能否渲染"全部允许"）
    public var hasCriticalIssue: Bool {
        if severity == .critical { return true }
        return issues.contains { $0.severity == .critical }
    }
}

public struct HipsIssue: Identifiable, Sendable {
    public let id: String // issue_id
    public let ruleId: String
    public let title: String
    public let severity: Severity
    public let allowRemember: Bool
    public let context: HipsContext
    public let recommendation: Recommendation?

    public init(
        id: String,
        ruleId: String,
        title: String,
        severity: Severity,
        allowRemember: Bool,
        context: HipsContext,
        recommendation: Recommendation?
    ) {
        self.id = id
        self.ruleId = ruleId
        self.title = title
        self.severity = severity
        self.allowRemember = allowRemember
        self.context = context
        self.recommendation = recommendation
    }
}
