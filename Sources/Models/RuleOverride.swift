import Foundation

/// Custom preset 单条规则的本地覆盖状态（DetectionPresetView 使用，可单元测试）。
public struct RuleOverride: Sendable, Equatable {
    public let ruleId: String
    /// 超时秒数（daemon 约束 30~600）。初始化时 clamp。
    public var timeoutSeconds: Int
    /// 超时后默认行为（Custom preset 覆盖只允许 block / allow）。
    public var defaultOnTimeout: String

    public static let minTimeout = 30
    public static let maxTimeout = 600
    public static let validDefaults: Set<String> = ["block", "allow"]

    public init(ruleId: String, timeoutSeconds: Int, defaultOnTimeout: String) {
        self.ruleId = ruleId
        self.timeoutSeconds = max(RuleOverride.minTimeout, min(RuleOverride.maxTimeout, timeoutSeconds))
        self.defaultOnTimeout = defaultOnTimeout
    }
}

/// Selection guard for Detection Preset cards.
/// SPEC-003 only asks for confirmation when switching to a different preset.
public struct DetectionPresetSelectionState: Sendable, Equatable {
    public private(set) var current: Preset
    public private(set) var pending: Preset?

    public init(current: Preset, pending: Preset? = nil) {
        self.current = current
        self.pending = pending
    }

    @discardableResult
    public mutating func select(_ preset: Preset) -> Bool {
        guard preset != current else {
            pending = nil
            return false
        }
        pending = preset
        return true
    }

    public mutating func cancel() {
        pending = nil
    }

    public mutating func applyPending() -> Preset? {
        guard let pending else { return nil }
        current = pending
        self.pending = nil
        return current
    }

    public mutating func syncCurrent(_ preset: Preset) {
        current = preset
        if pending == preset {
            pending = nil
        }
    }
}
