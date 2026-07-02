import Foundation

/// 跟踪本地已发出但未收到响应的请求 id。
/// - 重连后用于决定哪些消息需要重发
/// - 持有 CheckedContinuation，让 `sendRequest` 调用方可以 await 响应
public actor InflightQueue {
    public struct Entry: Sendable {
        public let id: String
        public let method: String
        public let payload: Data
        public let createdAt: Date
        public let isDecisionResponse: Bool // 决定优先级：true 优先重发
    }

    public enum AwaitError: Error, Sendable, Equatable {
        case rpcError(code: Int, message: String, data: Data?)
        case canceled
        case versionMismatch
        /// 重连后旧 inflight 被丢弃（SPEC-005 §3.4）
        case reconnectedDiscarded
        /// daemon 静默：超过 deadline 仍无响应（SPEC-008 §6，evaluate 90s / 其他 60s，OQ-008-02）
        case timeout

        public static func == (lhs: AwaitError, rhs: AwaitError) -> Bool {
            switch (lhs, rhs) {
            case let (.rpcError(c1, m1, _), .rpcError(c2, m2, _)): c1 == c2 && m1 == m2
            case (.canceled, .canceled): true
            case (.versionMismatch, .versionMismatch): true
            case (.reconnectedDiscarded, .reconnectedDiscarded): true
            case (.timeout, .timeout): true
            default: false
            }
        }
    }

    /// inflight 超时阈值（SPEC-008 §6 / OQ-008-02）。
    /// - `evaluate` 类慢方法（大 payload）：90s
    /// - 其他方法：60s
    public struct TimeoutPolicy: Sendable {
        public let defaultSeconds: TimeInterval
        public let evaluateSeconds: TimeInterval

        public init(defaultSeconds: TimeInterval = 60, evaluateSeconds: TimeInterval = 90) {
            self.defaultSeconds = defaultSeconds
            self.evaluateSeconds = evaluateSeconds
        }

        /// 按 method 名返回 deadline 时长。包含 "evaluate" 的方法走 evaluate 阈值。
        public func deadline(forMethod method: String) -> TimeInterval {
            method.contains("evaluate") ? evaluateSeconds : defaultSeconds
        }

        public static let `default` = TimeoutPolicy()
    }

    private var entries: [String: Entry] = [:]
    private var waiters: [String: CheckedContinuation<Data, Error>] = [:]

    public init() {}

    public func enqueue(_ entry: Entry) {
        entries[entry.id] = entry
    }

    public func registerWaiter(id: String, continuation: CheckedContinuation<Data, Error>) {
        waiters[id] = continuation
    }

    /// daemon 返回成功 result：唤醒等待者并清掉条目
    public func fulfill(id: String, resultData: Data) {
        entries.removeValue(forKey: id)
        if let cont = waiters.removeValue(forKey: id) {
            cont.resume(returning: resultData)
        }
    }

    /// daemon 返回错误 response：唤醒等待者抛 RPC 错误
    public func reject(id: String, code: Int, message: String, data: Data?) {
        entries.removeValue(forKey: id)
        if let cont = waiters.removeValue(forKey: id) {
            cont.resume(throwing: AwaitError.rpcError(code: code, message: message, data: data))
        }
    }

    /// 协议版本不识别等终态：所有 waiter 失败
    public func failAll(error: AwaitError) {
        for (_, cont) in waiters {
            cont.resume(throwing: error)
        }
        waiters.removeAll()
        entries.removeAll()
    }

    public func allPending() -> [Entry] {
        entries.values.sorted { lhs, rhs in
            if lhs.isDecisionResponse != rhs.isDecisionResponse { return lhs.isDecisionResponse }
            return lhs.createdAt < rhs.createdAt
        }
    }

    public func count() -> Int {
        entries.count
    }

    public func waiterCount() -> Int {
        waiters.count
    }

    /// 清空所有 pending entries 并对所有 waiter 抛 .reconnectedDiscarded（重连后丢弃）。
    /// SPEC-005 §3.4：重连后不重发 inflight，旧的 oneshot channel 已失效。
    public func clearAndDiscard() {
        for (_, cont) in waiters {
            cont.resume(throwing: AwaitError.reconnectedDiscarded)
        }
        waiters.removeAll()
        entries.removeAll()
    }

    /// 仅清 entries，不通知 waiters（内部用途）。
    public func clear() {
        entries.removeAll()
    }

    /// 超时清扫：对所有超过 deadline（按 method 区分，SPEC-008 §6 / OQ-008-02）的 entry，
    /// 以 `.timeout` 错误 reject 对应 waiter 并移除 entry，防止 daemon 静默时 await 永久挂起。
    /// 无 waiter 的 entry（fire-and-forget）也一并清掉，避免 entries 泄漏。
    /// - Parameters:
    ///   - now: 当前时间（测试可注入）。
    ///   - policy: 超时策略（按 method 给 deadline）。
    /// - Returns: 被清扫掉的 entry id 列表（供调用方做关联清理，如 mutating id 集合）。
    @discardableResult
    public func sweepTimeouts(now: Date = Date(), policy: TimeoutPolicy = .default) -> [String] {
        var expired: [String] = []
        for (id, entry) in entries {
            let deadline = policy.deadline(forMethod: entry.method)
            if now.timeIntervalSince(entry.createdAt) >= deadline {
                expired.append(id)
            }
        }
        for id in expired {
            entries.removeValue(forKey: id)
            if let cont = waiters.removeValue(forKey: id) {
                cont.resume(throwing: AwaitError.timeout)
            }
        }
        return expired
    }
}
