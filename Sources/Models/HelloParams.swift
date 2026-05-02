import Foundation

public struct HelloParams: Codable, Sendable {
    public let protocolVersion: String
    public let daemonVersion: String
    public let paused: Bool
    public let preset: Preset
    public let uptimeSeconds: Int
    public let auditDbUserVersion: Int

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case daemonVersion = "daemon_version"
        case paused
        case preset
        case uptimeSeconds = "uptime_seconds"
        case auditDbUserVersion = "audit_db_user_version"
    }
}

public struct PresetChangedParams: Codable, Sendable {
    public let preset: Preset
    public let changedBy: String
    public let occurredAt: String?

    enum CodingKeys: String, CodingKey {
        case preset
        case changedBy = "changed_by"
        case occurredAt = "occurred_at"
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
