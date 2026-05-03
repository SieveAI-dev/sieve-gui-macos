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
        public let isDecisionResponse: Bool   // 决定优先级：true 优先重发
    }

    public enum AwaitError: Error, Sendable, Equatable {
        case rpcError(code: Int, message: String, data: Data?)
        case canceled
        case versionMismatch
        /// 重连后旧 inflight 被丢弃（SPEC-005 §3.4）
        case reconnectedDiscarded

        public static func == (lhs: AwaitError, rhs: AwaitError) -> Bool {
            switch (lhs, rhs) {
            case (.rpcError(let c1, let m1, _), .rpcError(let c2, let m2, _)): return c1 == c2 && m1 == m2
            case (.canceled, .canceled): return true
            case (.versionMismatch, .versionMismatch): return true
            case (.reconnectedDiscarded, .reconnectedDiscarded): return true
            default: return false
            }
        }
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

    public func count() -> Int { entries.count }
    public func waiterCount() -> Int { waiters.count }

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
    public func clear() { entries.removeAll() }
}
