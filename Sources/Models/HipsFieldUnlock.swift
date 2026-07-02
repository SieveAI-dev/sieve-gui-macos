import Foundation

/// HIPS 弹窗内敏感字段的解锁态——与 History 的 `AppState.unlockSession` **完全隔离**
/// （SPEC-002 §4.4 隔离决策落地）。
///
/// 语义：
/// - 解锁绑定 `request_id`，仅对当前弹窗有效；换弹窗（新 request_id）自动失效，
///   即使 SwiftUI @State 因 rootView 复用而存活也不会跨弹窗泄漏。
/// - 认证走一次性「人在场」路径（不建立会话），History 的 5 分钟解锁不放行 HIPS，
///   HIPS 的解锁也不影响 History。
/// - 无 TTL：弹窗本身有 daemon 倒计时兜底，关窗/换窗即失效。
public struct HipsFieldUnlock: Sendable, Equatable {
    private var unlockedRequestId: String?

    public init() {}

    /// 认证成功后调用：解锁仅限指定 request 的弹窗。
    public mutating func unlock(requestId: String) {
        unlockedRequestId = requestId
    }

    public mutating func reset() {
        unlockedRequestId = nil
    }

    /// 只有「当前请求 == 解锁时的请求」才视为已解锁。
    public func isUnlocked(for requestId: String) -> Bool {
        unlockedRequestId == requestId
    }
}
