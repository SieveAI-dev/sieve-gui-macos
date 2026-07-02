import Foundation

/// JSON-RPC 2.0 消息（GUI 侧解析与发送统一走此 enum）。
// MARK: - 出站参数结构体（SPEC-008 §7：禁止 [String: Any] 透传）

public struct SetPausedParams: Encodable, Sendable {
    public let minutes: Int
    public init(minutes: Int) {
        self.minutes = minutes
    }
}

public struct SetPresetParams: Encodable, Sendable {
    public let mode: String
    public init(mode: String) {
        self.mode = mode
    }
}

public struct RemoveGraylistParams: Encodable, Sendable {
    public let fingerprint: String
    public init(fingerprint: String) {
        self.fingerprint = fingerprint
    }
}

/// Custom preset 单条规则覆盖参数（SPEC-003 §4 / ipc-protocol §4.3）。
public struct SetPresetOverridesParams: Encodable, Sendable {
    /// 目标规则 ID（e.g. "OUT-01"）。
    public let ruleId: String
    /// 超时秒数（30~600，daemon 二次校验）。
    public let timeoutSeconds: Int
    /// 超时后默认行为（Custom preset 覆盖只允许 block / allow）。
    public let defaultOnTimeout: String

    public init(ruleId: String, timeoutSeconds: Int, defaultOnTimeout: String) {
        self.ruleId = ruleId
        self.timeoutSeconds = timeoutSeconds
        self.defaultOnTimeout = defaultOnTimeout
    }

    enum CodingKeys: String, CodingKey {
        case ruleId = "rule_id"
        case timeoutSeconds = "timeout_seconds"
        case defaultOnTimeout = "default_on_timeout"
    }
}

/// sieve.purge_history 请求参数（SPEC-005 §11B）。
/// confirmed_at：Touch ID 通过时刻（UTC ISO8601），用于 daemon 审计日志。
public struct PurgeHistoryParams: Encodable, Sendable {
    public let confirmedAt: String

    public init(confirmedAt: Date) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.confirmedAt = f.string(from: confirmedAt)
    }

    enum CodingKeys: String, CodingKey {
        case confirmedAt = "confirmed_at"
    }
}

public enum PurgeHistorySendDecision: Equatable, Sendable {
    case send
    case cancelSilently
    case blocked(String)

    public static func resolve(
        touchIDPassed: Bool,
        daemonStatus: DaemonStatus,
        purgeUnavailable: Bool,
        purging: Bool
    ) -> PurgeHistorySendDecision {
        guard touchIDPassed else { return .cancelSilently }
        if purging { return .blocked("清空操作正在进行中，请稍候") }
        if purgeUnavailable {
            return .blocked("daemon 版本过旧，不支持清空历史（需升级 daemon）")
        }
        if case .disconnected = daemonStatus {
            return .blocked("清空失败，请检查 daemon 连接状态")
        }
        return .send
    }
}

public struct DaemonSettingsActionAvailability: Equatable, Sendable {
    public let canReloadConfig: Bool
    public let canRunHealthCheck: Bool
    public let canRunDoctor: Bool

    public static func resolve(daemonStatus: DaemonStatus) -> DaemonSettingsActionAvailability {
        let disconnected = if case .disconnected = daemonStatus {
            true
        } else {
            false
        }
        return DaemonSettingsActionAvailability(
            canReloadConfig: !disconnected,
            canRunHealthCheck: true,
            canRunDoctor: true
        )
    }
}

public struct EvaluateParams: Encodable, Sendable {
    public let direction: String
    public let contentKind: String
    public let payload: String
    public let sourceAgent: String

    public init(direction: String, contentKind: String, payload: String, sourceAgent: String) {
        self.direction = direction
        self.contentKind = contentKind
        self.payload = payload
        self.sourceAgent = sourceAgent
    }

    enum CodingKeys: String, CodingKey {
        case direction
        case contentKind = "content_kind"
        case payload
        case sourceAgent = "source_agent"
    }
}

// MARK: -

public enum IPCIncoming: Sendable {
    case request(id: String, method: String, paramsData: Data)
    case notification(method: String, paramsData: Data)
    case response(id: String, resultData: Data)
    case errorResponse(id: String, code: Int, message: String, data: Data?)

    public static func decode(line: Data) throws -> IPCIncoming {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line),
              case let .object(dict) = value
        else {
            throw IPCError.parseError
        }
        guard let jsonrpc = dict["jsonrpc"]?.asString, jsonrpc == "2.0" else {
            throw IPCError.invalidRequest
        }
        let method = dict["method"]?.asString
        // JSON-RPC 2.0 允许 id 为 string 或 number。daemon 当前恒发 string，但这里同时兼容
        // number（转成 string）——否则 daemon 若改用数字 id，response 会被判成无 id/无 method
        // 而丢弃，对应请求全部走超时（跨仓 schema 漂移高危点的 GUI 侧防御）。
        let id = dict["id"]?.asString ?? dict["id"]?.asInt.map(String.init)
        let paramsData: Data = {
            if let p = dict["params"] { return (try? JSONEncoder().encode(p)) ?? Data("{}".utf8) }
            return Data("{}".utf8)
        }()

        if let method, let id {
            return .request(id: id, method: method, paramsData: paramsData)
        }
        if let method {
            return .notification(method: method, paramsData: paramsData)
        }
        if let id {
            if let err = dict["error"], case let .object(edict) = err {
                let code = edict["code"]?.asInt ?? -32603
                let msg = edict["message"]?.asString ?? "unknown_error"
                let edata = edict["data"].flatMap { try? JSONEncoder().encode($0) }
                return .errorResponse(id: id, code: code, message: msg, data: edata)
            }
            let result = dict["result"].map { (try? JSONEncoder().encode($0)) ?? Data("{}".utf8) } ?? Data("{}".utf8)
            return .response(id: id, resultData: result)
        }
        throw IPCError.invalidRequest
    }
}

public enum IPCError: Error, Sendable {
    case parseError
    case invalidRequest
    case methodNotFound
    case invalidParams
    case internalError
    case versionMismatch(received: String)
    case socketUnavailable
    case messageTooLarge(bytes: Int)
    case connectionClosed
    case heartbeatTimeout
}

/// 出站请求（GUI → daemon）封装，支持构造正确的 newline-delimited JSON 编码。
/// 公开 API 接受 `Encodable` 参数类型，禁止 `[String: Any]` 透传（SPEC-008 §7）。
public enum IPCOutbound {
    /// 发送通知（无参数版本）。
    public static func notification(method: String) -> Data {
        let dict: [String: Any] = ["jsonrpc": "2.0", "method": method]
        return encodeLine(dict)
    }

    /// 发送通知（Encodable 参数版本）。
    public static func notification(method: String, params: some Encodable) -> Data {
        var dict: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let p = encodeParams(params) { dict["params"] = p }
        return encodeLine(dict)
    }

    /// 发送请求（无参数版本）。
    public static func request(id: String, method: String) -> Data {
        let dict: [String: Any] = ["jsonrpc": "2.0", "method": method, "id": id]
        return encodeLine(dict)
    }

    /// 发送请求（Encodable 参数版本）。
    public static func request(id: String, method: String, params: some Encodable) -> Data {
        var dict: [String: Any] = ["jsonrpc": "2.0", "method": method, "id": id]
        if let p = encodeParams(params) { dict["params"] = p }
        return encodeLine(dict)
    }

    /// P2-1：result 只接受 Encodable（禁 [String:Any] 透传，SPEC-008 §7）。
    /// 经 encodeParams 转 JSONSerialization 对象后与既有 sortedKeys 管线一致，wire 字节不变。
    public static func response(id: String, result: some Encodable) -> Data {
        var dict: [String: Any] = ["jsonrpc": "2.0", "id": id]
        dict["result"] = encodeParams(result) ?? [String: Any]()
        return encodeLine(dict)
    }

    public static func errorResponse(id: String, code: Int, message: String) -> Data {
        let dict: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message]
        ]
        return encodeLine(dict)
    }

    /// Encodable → JSONSerialization 对象（保证 sortedKeys 输出一致性）。
    private static func encodeParams(_ params: some Encodable) -> Any? {
        guard let data = try? JSONEncoder().encode(params) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    static func encodeLine(_ dict: [String: Any]) -> Data {
        let opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard let body = try? JSONSerialization.data(withJSONObject: dict, options: opts) else {
            return Data("{}\n".utf8)
        }
        var out = body
        out.append(0x0A)
        return out
    }
}
