import Foundation

/// 一条失联期间作出、待重连后重发的决策载荷（单 issue 或合并）。
public enum PendingDecisionPayload: Sendable {
    case single(DecisionResponse, allowRemember: Bool)
    case merged(MergedDecisionResponse)

    /// 对应的 request_id（= JSON-RPC id），用于去重与重发寻址。
    public var requestId: String {
        switch self {
        case let .single(r, _): r.id
        case let .merged(m): m.id
        }
    }

    /// 重发时编码为 JSON-RPC response.result 子对象（P2-1：Codable，禁 [String:Any]）。
    public func wire() -> DecisionWire {
        switch self {
        case let .single(r, allowRemember): .single(r.wire(allowRemember: allowRemember))
        case let .merged(m): .merged(m.wire())
        }
    }
}

/// 决策响应 result 的统一 Encodable 载体（单 issue / merged 两态，直接透传编码）。
public enum DecisionWire: Encodable, Sendable {
    case single(DecisionResultWire)
    case merged(MergedDecisionResultWire)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case let .single(w): try w.encode(to: encoder)
        case let .merged(w): try w.encode(to: encoder)
        }
    }
}

/// SPEC-002 §6：HIPS 失联期间用户决策的本地缓存。
///
/// - 失联时用户作出的决策存入此处（而非直接发 IPC）。
/// - `IPCClient` 重连成功后，`HipsPanelManager` 调 `drain()` 遍历重发全部缓存 response。
/// - daemon 端按 `request_id` 去重，故与 `IPCClient` inflight 兜底双发是安全的。
/// - 同 `request_id` 多次决策 → 后者覆盖（保留首次入队顺序），避免重发矛盾响应。
public struct DisconnectedDecisionCache: Sendable {
    /// 入队顺序（去重后每个 request_id 仅一条）。
    private var order: [String] = []
    /// request_id → 最新决策。
    private var byId: [String: PendingDecisionPayload] = [:]

    public init() {}

    public var count: Int {
        order.count
    }

    public var isEmpty: Bool {
        order.isEmpty
    }

    /// 缓存一条失联期间的决策。按 `request_id` 去重：后者覆盖，保留首次入队顺序。
    public mutating func store(_ payload: PendingDecisionPayload) {
        let id = payload.requestId
        if byId[id] == nil { order.append(id) }
        byId[id] = payload
    }

    /// 取出全部缓存决策（按入队顺序）并清空缓存。重连后重发用，清空防重复重发。
    public mutating func drain() -> [PendingDecisionPayload] {
        let result = order.compactMap { byId[$0] }
        order.removeAll()
        byId.removeAll()
        return result
    }
}
