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

    public enum AwaitError: Error, Sendable {
        case rpcError(code: Int, message: String, data: Data?)
        case canceled
        case versionMismatch
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
    public func clear() { entries.removeAll() }
}
