import Foundation

/// 跟踪本 GUI 发出的 mutating request id（sieve.set_preset / sieve.set_paused 等）。
/// 用于 preset_changed / paused_changed 通知的回声判定：
/// origin_request_id ∈ 集合 → 本 GUI 发出，跳过更新（已乐观更新过）；否则更新状态。
///
/// 每个 id 带 60s TTL 兜底：正常路径靠调用方 unregister 移除，但若某 unregister 被漏掉
/// 或对应 Task 被取消，TTL 防止 id 永久驻留——否则后续**真正的**外部 preset_changed /
/// paused_changed 会被误判为回声而静默丢弃（echo 机制反向失效）。
public actor InflightMutatingSet {
    private var ids: [String: Date] = [:]
    private let ttl: TimeInterval

    public init(ttl: TimeInterval = 60) {
        self.ttl = ttl
    }

    public func insert(_ id: String) {
        ids[id] = Date()
    }

    public func remove(_ id: String) {
        ids.removeValue(forKey: id)
    }

    public func contains(_ id: String) -> Bool {
        pruneExpired()
        return ids[id] != nil
    }

    public func clear() {
        ids.removeAll()
    }

    public func count() -> Int {
        pruneExpired()
        return ids.count
    }

    /// 剔除超过 TTL 的条目（防漏 unregister 致 id 永驻）。
    private func pruneExpired() {
        let now = Date()
        ids = ids.filter { now.timeIntervalSince($0.value) < ttl }
    }
}
