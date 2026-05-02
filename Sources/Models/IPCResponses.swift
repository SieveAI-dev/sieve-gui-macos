import Foundation

/// IPC 响应体的 Codable 结构。命名对照 docs/api/ipc-protocol.md。

public struct SetPausedResult: Decodable, Sendable {
    public let pausedUntil: String
    public let criticalStillBlocks: Bool

    enum CodingKeys: String, CodingKey {
        case pausedUntil = "paused_until"
        case criticalStillBlocks = "critical_still_blocks"
    }
}

public struct SetPresetOk: Decodable, Sendable {
    public let ok: Bool
}

public struct ReloadConfigResult: Decodable, Sendable {
    public let ok: Bool
    public let rulesLoaded: Int?
    public let userRulesLoaded: Int?
    public let warnings: [String]?

    enum CodingKeys: String, CodingKey {
        case ok
        case rulesLoaded = "rules_loaded"
        case userRulesLoaded = "user_rules_loaded"
        case warnings
    }
}

public struct EvaluateResult: Decodable, Sendable {
    public let evaluatedRules: Int
    public let matches: [Match]
    public let noMatch: [String]?

    enum CodingKeys: String, CodingKey {
        case evaluatedRules = "evaluated_rules"
        case matches
        case noMatch = "no_match"
    }

    public struct Match: Decodable, Sendable, Identifiable {
        public var id: String { ruleId }
        public let ruleId: String
        public let severity: Severity
        public let disposition: String
        public let matchedPattern: String?
        public let matchedCanonical: String?
        public let fields: [String]?
        public let redactedEvidence: String?

        enum CodingKeys: String, CodingKey {
            case ruleId = "rule_id"
            case severity, disposition
            case matchedPattern = "matched_pattern"
            case matchedCanonical = "matched_canonical"
            case fields
            case redactedEvidence = "redacted_evidence"
        }
    }
}

public struct HealthResultDTO: Decodable, Sendable {
    public let ok: Bool
    public let checks: [Check]
    public let metrics: Metrics?

    public struct Check: Decodable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let ok: Bool
        public let detail: String?
    }

    public struct Metrics: Decodable, Sendable {
        public let p99LatencyMs: Int?
        public let throughput1h: Int?
        public let goroutines: Int?

        enum CodingKeys: String, CodingKey {
            case p99LatencyMs = "p99_latency_ms"
            case throughput1h = "throughput_1h"
            case goroutines
        }
    }
}
