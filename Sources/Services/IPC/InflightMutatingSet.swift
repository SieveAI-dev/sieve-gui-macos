import Foundation

/// 跟踪本 GUI 发出的 mutating request id（sieve.set_preset / sieve.set_paused 等）。
/// 用于 preset_changed / paused_changed 通知的回声判定：
/// origin_request_id ∈ 集合 → 本 GUI 发出，跳过更新（已乐观更新过）；否则更新状态。
public actor InflightMutatingSet {
    private var ids: Set<String> = []

    public init() {}

    public func insert(_ id: String) {
        ids.insert(id)
    }

    public func remove(_ id: String) {
        ids.remove(id)
    }

    public func contains(_ id: String) -> Bool {
        ids.contains(id)
    }

    public func clear() {
        ids.removeAll()
    }

    public func count() -> Int { ids.count }
}
