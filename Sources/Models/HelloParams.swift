import Foundation

public struct HelloParams: Codable, Sendable {
    public let protocolVersion: String
    public let daemonVersion: String
    public let daemonBootId: String
    public let paused: Bool
    public let preset: Preset
    public let uptimeSeconds: Int
    public let auditDbUserVersion: Int

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case daemonVersion = "daemon_version"
        case daemonBootId = "daemon_boot_id"
        case paused
        case preset
        case uptimeSeconds = "uptime_seconds"
        case auditDbUserVersion = "audit_db_user_version"
    }
}

public struct PresetChangedParams: Codable, Sendable {
    public let mode: String
    public let changedAt: Date
    public let source: String
    public let originRequestId: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case changedAt = "changed_at"
        case source
        case originRequestId = "origin_request_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(String.self, forKey: .mode)
        source = try container.decode(String.self, forKey: .source)
        originRequestId = try container.decodeIfPresent(String.self, forKey: .originRequestId)
        // changed_at 是 ISO8601 字符串
        let s = try container.decode(String.self, forKey: .changedAt)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) {
            changedAt = d
        } else {
            f.formatOptions = [.withInternetDateTime]
            changedAt = f.date(from: s) ?? Date()
        }
    }
}

public struct RequestCanceledParams: Codable, Sendable {
    public let requestId: String
    public let reason: String

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case reason
    }
}

public struct PausedChangedParams: Codable, Sendable {
    public let paused: Bool
    public let pausedUntil: Date?
    public let reason: String?
    public let appliesTo: [String]
    public let source: String
    public let originRequestId: String?

    enum CodingKeys: String, CodingKey {
        case paused
        case pausedUntil = "paused_until"
        case reason
        case appliesTo = "applies_to"
        case source
        case originRequestId = "origin_request_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paused = try container.decode(Bool.self, forKey: .paused)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        appliesTo = try container.decodeIfPresent([String].self, forKey: .appliesTo) ?? []
        source = try container.decode(String.self, forKey: .source)
        originRequestId = try container.decodeIfPresent(String.self, forKey: .originRequestId)
        // paused_until 是 ISO8601 字符串，需手动解析
        if let s = try container.decodeIfPresent(String.self, forKey: .pausedUntil) {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) {
                pausedUntil = d
            } else {
                f.formatOptions = [.withInternetDateTime]
                pausedUntil = f.date(from: s)
            }
        } else {
            pausedUntil = nil
        }
    }
}

/// `sieve.notify_status_bar` 通知 payload。对照 SPEC-005 §10.1 daemon `StatusBarNotify`：
/// daemon 发 notify_id / created_at / kind(snake_case) / title / detail? / rule_id? /
/// auto_dismiss_seconds。GUI 解码字段逐一对齐 daemon wire（无 severity/direction/summary 等）。
public struct EventNotifyParams: Codable, Sendable {
    /// 通知唯一 ID（UUID 串）
    public let notifyId: String
    /// 通知生成时刻（ISO8601 串）
    public let createdAt: Date
    public let kind: NotifyKind
    /// 主标题（用户可见）
    public let title: String
    /// 可选详情（用户可见，可空）
    public let detail: String?
    /// 关联规则 ID（可空）
    public let ruleId: String?
    /// 建议自动消失秒数（0 = 不自动消失）
    public let autoDismissSeconds: UInt32

    enum CodingKeys: String, CodingKey {
        case notifyId = "notify_id"
        case createdAt = "created_at"
        case kind
        case title
        case detail
        case ruleId = "rule_id"
        case autoDismissSeconds = "auto_dismiss_seconds"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notifyId = try c.decode(String.self, forKey: .notifyId)
        kind = try c.decode(NotifyKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        ruleId = try c.decodeIfPresent(String.self, forKey: .ruleId)
        autoDismissSeconds = try c.decode(UInt32.self, forKey: .autoDismissSeconds)
        // created_at 是 ISO8601 字符串
        let s = try c.decode(String.self, forKey: .createdAt)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) {
            createdAt = d
        } else {
            f.formatOptions = [.withInternetDateTime]
            createdAt = f.date(from: s) ?? Date()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(notifyId, forKey: .notifyId)
        try c.encode(kind, forKey: .kind)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(ruleId, forKey: .ruleId)
        try c.encode(autoDismissSeconds, forKey: .autoDismissSeconds)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try c.encode(f.string(from: createdAt), forKey: .createdAt)
    }
}
