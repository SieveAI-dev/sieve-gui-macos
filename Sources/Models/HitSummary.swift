import Foundation

/// 菜单栏 / Toast / 调试窗口共用的命中摘要——绝不包含原始 prompt。
public struct HitSummary: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let ruleId: String
    public let action: Action
    public let direction: Direction
    public let severity: Severity
    public let occurredAt: Date
    public let auditEventId: Int64?

    public enum Action: String, Sendable {
        case allow, deny, redact, marked, terminal
    }

    public init(
        id: UUID = UUID(),
        ruleId: String,
        action: Action,
        direction: Direction,
        severity: Severity,
        occurredAt: Date,
        auditEventId: Int64?
    ) {
        self.id = id
        self.ruleId = ruleId
        self.action = action
        self.direction = direction
        self.severity = severity
        self.occurredAt = occurredAt
        self.auditEventId = auditEventId
    }
}

/// audit.db events 表的一行（GUI 唯一直接查询的表）
public struct AuditEventRow: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let createdAt: Date
    public let direction: Direction
    public let severity: Severity
    public let ruleId: String
    public let disposition: String
    public let userChoice: String?
    public let fingerprint: String?
    public let sessionId: String?
    public let callerPid: Int?          // v2 schema
    public let callerExe: String?       // v2 schema
    public let evidenceMetaJSON: String?
    public let requestId: String?

    public init(
        id: Int64,
        createdAt: Date,
        direction: Direction,
        severity: Severity,
        ruleId: String,
        disposition: String,
        userChoice: String?,
        fingerprint: String?,
        sessionId: String?,
        callerPid: Int?,
        callerExe: String?,
        evidenceMetaJSON: String?,
        requestId: String?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.direction = direction
        self.severity = severity
        self.ruleId = ruleId
        self.disposition = disposition
        self.userChoice = userChoice
        self.fingerprint = fingerprint
        self.sessionId = sessionId
        self.callerPid = callerPid
        self.callerExe = callerExe
        self.evidenceMetaJSON = evidenceMetaJSON
        self.requestId = requestId
    }
}

public struct GraylistEntry: Identifiable, Sendable, Equatable, Decodable {
    public var id: String { fingerprint }
    public let fingerprint: String
    public let ruleId: String
    /// added_at: Unix milliseconds timestamp (SPEC-005 §9.7)
    public let addedAt: Date
    public let contextHint: String?
    public let matchCountSince: Int
    public let ruleKind: String
    public let addedBy: String

    public init(fingerprint: String, ruleId: String, addedAt: Date, contextHint: String?,
                matchCountSince: Int, ruleKind: String, addedBy: String) {
        self.fingerprint = fingerprint
        self.ruleId = ruleId
        self.addedAt = addedAt
        self.contextHint = contextHint
        self.matchCountSince = matchCountSince
        self.ruleKind = ruleKind
        self.addedBy = addedBy
    }

    enum CodingKeys: String, CodingKey {
        case fingerprint
        case ruleId = "rule_id"
        case addedAt = "added_at"
        case contextHint = "context_hint"
        case matchCountSince = "match_count_since"
        case ruleKind = "rule_kind"
        case addedBy = "added_by"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.fingerprint = try c.decode(String.self, forKey: .fingerprint)
        self.ruleId = try c.decode(String.self, forKey: .ruleId)
        self.contextHint = try c.decodeIfPresent(String.self, forKey: .contextHint)
        self.matchCountSince = try c.decodeIfPresent(Int.self, forKey: .matchCountSince) ?? 0
        self.ruleKind = try c.decodeIfPresent(String.self, forKey: .ruleKind) ?? "unknown"
        self.addedBy = try c.decodeIfPresent(String.self, forKey: .addedBy) ?? "unknown"
        // added_at: Unix milliseconds integer
        let ms = try c.decodeIfPresent(Int64.self, forKey: .addedAt) ?? 0
        self.addedAt = Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }
}

public struct GraylistResponse: Decodable, Sendable {
    public let entries: [GraylistEntry]
}

public struct HealthResult: Sendable {
    public let ok: Bool
    public let checks: [Check]
    public let metrics: Metrics

    public struct Check: Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let ok: Bool
        public let detail: String?
    }

    public struct Metrics: Sendable {
        public let p99LatencyMs: Int
        public let throughput1h: Int
        public let goroutines: Int
    }
}

public struct UnlockSession: Sendable {
    public let unlockedAt: Date
    public let expiresAt: Date

    public init(unlockedAt: Date = Date(), validFor seconds: TimeInterval = 300) {
        self.unlockedAt = unlockedAt
        self.expiresAt = unlockedAt.addingTimeInterval(seconds)
    }

    public func isValid(now: Date = Date()) -> Bool { now < expiresAt }
}
