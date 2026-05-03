import Foundation

/// 把 `sieve.request_decision` 的 params 解码为 `HipsRequest`。
/// 未知 template → 降级到 `.generic`。未知字段忽略（JSON-RPC 协议层硬约束）。
public enum HipsRequestDecoder {
    public enum DecodeError: Error {
        case missingField(String)
        case typeMismatch(String)
    }

    public static func decode(id: String, paramsData: Data) throws -> HipsRequest {
        let value = try JSONDecoder().decode(JSONValue.self, from: paramsData)
        guard case .object(let dict) = value else {
            throw DecodeError.typeMismatch("params not object")
        }

        let requestId = try dict.requireString("request_id")
        let title = try dict.requireString("title")
        guard let severity = Severity(rawValue: try dict.requireString("severity")) else {
            throw DecodeError.typeMismatch("severity")
        }
        guard let direction = Direction(rawValue: try dict.requireString("direction")) else {
            throw DecodeError.typeMismatch("direction")
        }
        let timeoutSeconds = try dict.requireInt("timeout_seconds")
        guard let defaultOnTimeout = DefaultOnTimeout(rawValue: try dict.requireString("default_on_timeout")) else {
            throw DecodeError.typeMismatch("default_on_timeout")
        }
        let allowRemember = try dict.requireBool("allow_remember")
        let merged = (try? dict.requireBool("merged")) ?? false
        let receivedAtDaemon = parseDate(dict["received_at_daemon"]?.asString)

        if merged {
            let issuesArray: [JSONValue]
            if case .array(let arr) = dict["issues"] ?? .null { issuesArray = arr } else { issuesArray = [] }
            let issues = issuesArray.compactMap(decodeIssue)

            return HipsRequest(
                id: id,
                requestId: requestId,
                title: title,
                severity: severity,
                direction: direction,
                timeoutSeconds: timeoutSeconds,
                defaultOnTimeout: defaultOnTimeout,
                allowRemember: allowRemember,
                merged: true,
                receivedAtDaemon: receivedAtDaemon,
                ruleId: nil,
                context: nil,
                recommendation: nil,
                issues: issues,
                rawJSON: paramsData
            )
        }

        let ruleId = dict["rule_id"]?.asString
        let context = decodeContextOptional(dict["context"])
        let recommendation = decodeRecommendation(dict["recommendation"] ?? .null)

        return HipsRequest(
            id: id,
            requestId: requestId,
            title: title,
            severity: severity,
            direction: direction,
            timeoutSeconds: timeoutSeconds,
            defaultOnTimeout: defaultOnTimeout,
            allowRemember: allowRemember,
            merged: false,
            receivedAtDaemon: receivedAtDaemon,
            ruleId: ruleId,
            context: context,
            recommendation: recommendation,
            issues: [],
            rawJSON: paramsData
        )
    }

    private static func decodeIssue(_ value: JSONValue) -> HipsIssue? {
        guard case .object(let d) = value else { return nil }
        guard let issueId = d["issue_id"]?.asString,
              let ruleId = d["rule_id"]?.asString,
              let title = d["title"]?.asString,
              let sevRaw = d["severity"]?.asString,
              let severity = Severity(rawValue: sevRaw),
              let allowRemember = d["allow_remember"]?.asBool
        else { return nil }
        return HipsIssue(
            id: issueId,
            ruleId: ruleId,
            title: title,
            severity: severity,
            allowRemember: allowRemember,
            context: decodeContext(d["context"] ?? .null),
            recommendation: decodeRecommendation(d["recommendation"] ?? .null)
        )
    }

    /// 顶层 context 解码：null / 缺失 → nil（SPEC §6.1.1 context no/null yes）
    private static func decodeContextOptional(_ value: JSONValue?) -> HipsContext? {
        guard let value, value != .null else { return nil }
        return decodeContext(value)
    }

    private static func decodeContext(_ value: JSONValue) -> HipsContext {
        guard case .object(let dict) = value else {
            return .generic(.init(payload: .init(rawData: encode(value))))
        }
        let template = dict["template"]?.asString ?? "generic_json"
        let body = encode(value)

        let dec = JSONDecoder()
        switch template {
        case "address_compare":
            if let v = try? dec.decode(HipsContext.AddressCompare.self, from: body) { return .addressCompare(v) }
        case "signing_tool_use":
            if let v = try? dec.decode(HipsContext.SigningToolUse.self, from: body) { return .signingToolUse(v) }
        case "markdown_exfil":
            if let v = try? dec.decode(HipsContext.MarkdownExfil.self, from: body) { return .markdownExfil(v) }
        case "secret_outbound":
            if let v = try? dec.decode(HipsContext.SecretOutbound.self, from: body) { return .secretOutbound(v) }
        default:
            break
        }
        return .generic(.init(payload: .init(rawData: body)))
    }

    private static func decodeRecommendation(_ value: JSONValue) -> Recommendation? {
        guard case .object(let d) = value,
              let decRaw = d["decision"]?.asString,
              let decision = Decision(rawValue: decRaw),
              let confRaw = d["confidence"]?.asString,
              let confidence = RecommendationConfidence(rawValue: confRaw)
        else { return nil }
        return Recommendation(decision: decision, confidence: confidence, reason: d["reason"]?.asString)
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func encode(_ value: JSONValue) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    }
}

// MARK: - JSONValue helpers

extension JSONValue {
    var asString: String? { if case .string(let s) = self { return s } else { return nil } }
    var asInt: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }
    var asBool: Bool? { if case .bool(let v) = self { return v } else { return nil } }
}

extension Dictionary where Key == String, Value == JSONValue {
    func requireString(_ key: String) throws -> String {
        guard let v = self[key]?.asString else { throw HipsRequestDecoder.DecodeError.missingField(key) }
        return v
    }
    func requireInt(_ key: String) throws -> Int {
        guard let v = self[key]?.asInt else { throw HipsRequestDecoder.DecodeError.missingField(key) }
        return v
    }
    func requireBool(_ key: String) throws -> Bool {
        guard let v = self[key]?.asBool else { throw HipsRequestDecoder.DecodeError.missingField(key) }
        return v
    }
}
