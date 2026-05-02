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
    public let preset: Preset
    public let mode: String
    public let changedAt: Date
    public let source: String
    public let originRequestId: String?

    enum CodingKeys: String, CodingKey {
        case preset
        case mode
        case changedAt = "changed_at"
        case source
        case originRequestId = "origin_request_id"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preset = try container.decode(Preset.self, forKey: .preset)
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

public struct EventNotifyParams: Codable, Sendable {
    public let kind: NotifyKind
    public let ruleId: String
    public let severity: Severity
    public let direction: Direction
    public let disposition: String
    public let summary: String
    public let count: Int?
    public let auditEventId: Int64?
    public let occurredAt: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case ruleId = "rule_id"
        case severity, direction, disposition, summary, count
        case auditEventId = "audit_event_id"
        case occurredAt = "occurred_at"
    }
}
