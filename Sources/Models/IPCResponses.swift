import Foundation

/// IPC 响应体的 Codable 结构。命名对照 docs/api/ipc-protocol.md。

public struct SetPausedResult: Decodable, Sendable {
    public let paused: Bool
    public let pausedUntil: Date?
    public let appliesTo: [String]

    enum CodingKeys: String, CodingKey {
        case paused
        case pausedUntil = "paused_until"
        case appliesTo = "applies_to"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        paused = try c.decode(Bool.self, forKey: .paused)
        appliesTo = try c.decodeIfPresent([String].self, forKey: .appliesTo) ?? []
        // paused_until is ISO8601 string, optional
        if let s = try c.decodeIfPresent(String.self, forKey: .pausedUntil) {
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
    public let matches: [Match]
    public let noMatch: [String]?

    enum CodingKeys: String, CodingKey {
        case matches
        case noMatch = "no_match"
    }

    public struct Match: Decodable, Sendable, Identifiable {
        public var id: String { ruleId }
        public let ruleId: String
        public let severity: Severity
        public let disposition: String
        public let matchedPatternSummary: String?
        public let fieldsTriggered: [String]?
        public let evaluatedAt: Date?
        public let ruleKind: String
        public let wouldDecision: String
        public let wouldRecommendation: String?

        enum CodingKeys: String, CodingKey {
            case ruleId = "rule_id"
            case severity, disposition
            case matchedPatternSummary = "matched_pattern_summary"
            case fieldsTriggered = "fields_triggered"
            case evaluatedAt = "evaluated_at"
            case ruleKind = "rule_kind"
            case wouldDecision = "would_decision"
            case wouldRecommendation = "would_recommendation"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ruleId = try c.decode(String.self, forKey: .ruleId)
            severity = try c.decode(Severity.self, forKey: .severity)
            disposition = try c.decode(String.self, forKey: .disposition)
            matchedPatternSummary = try c.decodeIfPresent(String.self, forKey: .matchedPatternSummary)
            fieldsTriggered = try c.decodeIfPresent([String].self, forKey: .fieldsTriggered)
            ruleKind = try c.decode(String.self, forKey: .ruleKind)
            wouldDecision = try c.decode(String.self, forKey: .wouldDecision)
            wouldRecommendation = try c.decodeIfPresent(String.self, forKey: .wouldRecommendation)
            // evaluated_at is Unix ms integer
            if let ms = try c.decodeIfPresent(Int64.self, forKey: .evaluatedAt) {
                evaluatedAt = Date(timeIntervalSince1970: Double(ms) / 1000.0)
            } else {
                evaluatedAt = nil
            }
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
