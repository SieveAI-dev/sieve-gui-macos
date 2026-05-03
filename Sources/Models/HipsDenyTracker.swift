import Foundation

/// 追踪每个 rule_id 最近一次 deny 时间，用于判断是否在时间窗口内再次弹同规则。
/// 可测：纯 Swift，不依赖 AppKit / SwiftUI。
public struct HipsDenyTracker: Sendable {
    /// 互换按钮位置的时间窗口（秒）
    public static let swapWindowSeconds: TimeInterval = 5

    private var lastDenyByRuleId: [String: Date] = [:]

    public init() {}

    /// 记录 deny 时间
    public mutating func recordDeny(ruleId: String, at date: Date = Date()) {
        lastDenyByRuleId[ruleId] = date
    }

    /// 判断 rule_id 在时间窗口内是否刚被 deny（返回 true → 应互换按钮布局）
    public func shouldSwapLayout(ruleId: String, now: Date = Date()) -> Bool {
        guard let lastDeny = lastDenyByRuleId[ruleId] else { return false }
        return now.timeIntervalSince(lastDeny) < HipsDenyTracker.swapWindowSeconds
    }
}
