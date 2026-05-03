import Foundation

/// Custom preset 单条规则的本地覆盖状态（DetectionPresetView 使用，可单元测试）。
public struct RuleOverride: Sendable, Equatable {
    public let ruleId: String
    /// 超时秒数（daemon 约束 30~600）。初始化时 clamp。
    public var timeoutSeconds: Int
    /// 超时后默认行为（block / allow / redact）。
    public var defaultOnTimeout: String

    public static let minTimeout = 30
    public static let maxTimeout = 600
    public static let validDefaults: Set<String> = ["block", "allow", "redact"]

    public init(ruleId: String, timeoutSeconds: Int, defaultOnTimeout: String) {
        self.ruleId = ruleId
        self.timeoutSeconds = max(RuleOverride.minTimeout, min(RuleOverride.maxTimeout, timeoutSeconds))
        self.defaultOnTimeout = defaultOnTimeout
    }
}
