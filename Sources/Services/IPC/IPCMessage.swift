import Foundation

/// JSON-RPC 2.0 消息（GUI 侧解析与发送统一走此 enum）。
public enum IPCIncoming: Sendable {
    case request(id: String, method: String, paramsData: Data)
    case notification(method: String, paramsData: Data)
    case response(id: String, resultData: Data)
    case errorResponse(id: String, code: Int, message: String, data: Data?)

    public static func decode(line: Data) throws -> IPCIncoming {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line),
              case .object(let dict) = value else {
            throw IPCError.parseError
        }
        guard let jsonrpc = dict["jsonrpc"]?.asString, jsonrpc == "2.0" else {
            throw IPCError.invalidRequest
        }
        let method = dict["method"]?.asString
        let id = dict["id"]?.asString
        let paramsData: Data = {
            if let p = dict["params"] { return (try? JSONEncoder().encode(p)) ?? Data("{}".utf8) }
            return Data("{}".utf8)
        }()

        if let method = method, let id = id {
            return .request(id: id, method: method, paramsData: paramsData)
        }
        if let method = method {
            return .notification(method: method, paramsData: paramsData)
        }
        if let id = id {
            if let err = dict["error"], case .object(let edict) = err {
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
public enum IPCOutbound {
    public static func notification(method: String, params: [String: Any]? = nil) -> Data {
        var dict: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { dict["params"] = params }
        return encodeLine(dict)
    }

    public static func request(id: String, method: String, params: [String: Any]? = nil) -> Data {
        var dict: [String: Any] = ["jsonrpc": "2.0", "method": method, "id": id]
        if let params { dict["params"] = params }
        return encodeLine(dict)
    }

    public static func response(id: String, result: [String: Any]) -> Data {
        let dict: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
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

    private static func encodeLine(_ dict: [String: Any]) -> Data {
        let opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard let body = try? JSONSerialization.data(withJSONObject: dict, options: opts) else {
            return Data("{}\n".utf8)
        }
        var out = body
        out.append(0x0A)
        return out
    }
}
