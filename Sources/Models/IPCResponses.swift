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
    public let systemRulesCount: Int
    public let userRulesCount: Int
    public let userRulesErrors: [String]
    public let reloadedAt: Date?

    enum CodingKeys: String, CodingKey {
        case systemRulesCount = "system_rules_count"
        case userRulesCount = "user_rules_count"
        case userRulesErrors = "user_rules_errors"
        case reloadedAt = "reloaded_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        systemRulesCount = try c.decodeIfPresent(Int.self, forKey: .systemRulesCount) ?? 0
        userRulesCount = try c.decodeIfPresent(Int.self, forKey: .userRulesCount) ?? 0
        userRulesErrors = try c.decodeIfPresent([String].self, forKey: .userRulesErrors) ?? []
        // reloaded_at is ISO8601 string
        if let s = try c.decodeIfPresent(String.self, forKey: .reloadedAt) {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) {
                reloadedAt = d
            } else {
                f.formatOptions = [.withInternetDateTime]
                reloadedAt = f.date(from: s)
            }
        } else {
            reloadedAt = nil
        }
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
        /// 可选：daemon evaluate 对非 critical_lock 命中可能回 `severity:"unknown"`（SPEC-005
        /// 枚举外取值，见 handle_evaluate），GUI `Severity` 无该 case → 容错为 nil（展示「未知」），
        /// 避免整个 EvaluateResult 解码失败丢结果。
        public let severity: Severity?
        public let disposition: String
        public let matchedPatternSummary: String?
        public let fieldsTriggered: [String]?
        public let evaluatedAt: Date?
        public let ruleKind: String
        public let wouldDecision: String
        /// SPEC-005 §6.1.4：would_recommendation 是 Recommendation 对象（可 null/省略），
        /// 与主 recommendation 字段同结构 {decision, confidence, reason}。
        public let wouldRecommendation: Recommendation?

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
            // 容错：未知 severity 字符串（如 daemon 的 "unknown"）→ nil，不丢整个结果。
            severity = (try c.decodeIfPresent(String.self, forKey: .severity)).flatMap(Severity.init(rawValue:))
            disposition = try c.decode(String.self, forKey: .disposition)
            matchedPatternSummary = try c.decodeIfPresent(String.self, forKey: .matchedPatternSummary)
            fieldsTriggered = try c.decodeIfPresent([String].self, forKey: .fieldsTriggered)
            ruleKind = try c.decode(String.self, forKey: .ruleKind)
            wouldDecision = try c.decode(String.self, forKey: .wouldDecision)
            wouldRecommendation = try c.decodeIfPresent(Recommendation.self, forKey: .wouldRecommendation)
            // evaluated_at is Unix ms integer
            if let ms = try c.decodeIfPresent(Int64.self, forKey: .evaluatedAt) {
                evaluatedAt = Date(timeIntervalSince1970: Double(ms) / 1000.0)
            } else {
                evaluatedAt = nil
            }
        }
    }
}

// MARK: - sieve.list_rules §11A

public struct ListRulesResult: Decodable, Sendable {
    public let rules: [RuleSummary]
}

/// 规则快照（11 字段）。对照 SPEC-005 §11A RuleSummary 字段表。
public struct RuleSummary: Decodable, Sendable, Identifiable {
    public var id: String { ruleId }

    public let ruleId: String
    public let title: String
    public let severity: Severity
    public let direction: Direction
    public let disposition: Disposition
    /// 仅 disposition == "gui_popup" 时有意义；其他情况 MUST 为 null
    public let defaultOnTimeout: DefaultOnTimeout?
    /// 仅 disposition == "gui_popup" 时有意义；其他情况 MUST 为 null
    public let timeoutSeconds: UInt32?
    public let criticalLock: Bool
    public let enabled: Bool
    public let ruleKind: RuleKind
    public let description: String?

    public enum RuleKind: String, Codable, Sendable {
        case system
        case user
    }

    enum CodingKeys: String, CodingKey {
        case ruleId = "rule_id"
        case title
        case severity
        case direction
        case disposition
        case defaultOnTimeout = "default_on_timeout"
        case timeoutSeconds = "timeout_seconds"
        case criticalLock = "critical_lock"
        case enabled
        case ruleKind = "rule_kind"
        case description
    }
}

// MARK: - sieve.purge_history §11B

/// purge_history 操作结果。对照 SPEC-005 §11B result 字段表。
public struct PurgeHistoryResult: Decodable, Sendable {
    /// daemon 实际完成删除的时刻（UTC）
    public let purgedAt: Date
    /// 本次删除的 audit event 行数（0 = 历史本就为空，也算成功）
    public let rowsDeleted: UInt64

    enum CodingKeys: String, CodingKey {
        case purgedAt = "purged_at"
        case rowsDeleted = "rows_deleted"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rowsDeleted = try c.decode(UInt64.self, forKey: .rowsDeleted)
        let s = try c.decode(String.self, forKey: .purgedAt)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) {
            purgedAt = d
        } else {
            f.formatOptions = [.withInternetDateTime]
            guard let d = f.date(from: s) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .purgedAt, in: c,
                    debugDescription: "purged_at is not a valid ISO8601 date: \(s)")
            }
            purgedAt = d
        }
    }
}

// MARK: - sieve.health §9.5

/// `sieve.health` 响应。对照 SPEC-005 §9.5（v2 + ADR-026 listeners[] 扩展）。
///
/// 字段语义：
/// - `listen` 与 `listeners[0]` 等价；`listen` 自 v2.x ADR-026 起标注 deprecated，
///   仅向后兼容旧 client 读取，本 client 优先消费 `listeners`。
/// - `listeners` 在旧 daemon 不发本字段时退化为空数组（`decodeIfPresent ?? []`），
///   client 应回落到 `listen` 单值展示。
public struct HealthResultDTO: Decodable, Sendable {
    public let daemonVersion: String
    public let protocolVersion: String
    public let startedAt: Date
    public let uptimeSeconds: UInt64
    public let preset: PresetSnapshot
    public let paused: Bool
    public let pausedUntil: Date?
    public let listen: ListenSnapshot
    public let listeners: [ListenerSnapshot]
    public let auditDb: AuditDbSnapshot
    public let rules: RulesSnapshot
    public let graylist: GraylistSnapshot
    public let ipc: IpcSnapshot

    enum CodingKeys: String, CodingKey {
        case daemonVersion = "daemon_version"
        case protocolVersion = "protocol_version"
        case startedAt = "started_at"
        case uptimeSeconds = "uptime_seconds"
        case preset
        case paused
        case pausedUntil = "paused_until"
        case listen
        case listeners
        case auditDb = "audit_db"
        case rules
        case graylist
        case ipc
    }

    public struct PresetSnapshot: Decodable, Sendable {
        public let mode: Preset
        public let overrides: [String: PresetOverrideValue]

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mode = try c.decode(Preset.self, forKey: .mode)
            overrides = try c.decodeIfPresent([String: PresetOverrideValue].self, forKey: .overrides) ?? [:]
        }

        enum CodingKeys: String, CodingKey { case mode, overrides }
    }

    public struct PresetOverrideValue: Decodable, Sendable {
        public let timeoutSeconds: UInt32
        public let defaultOnTimeout: DefaultOnTimeout

        enum CodingKeys: String, CodingKey {
            case timeoutSeconds = "timeout_seconds"
            case defaultOnTimeout = "default_on_timeout"
        }
    }

    /// 旧字段，等价于 `listeners[0]`（ADR-026 起 deprecated）。
    public struct ListenSnapshot: Decodable, Sendable {
        public let addr: String
        public let port: UInt16
    }

    /// 单 listener 完整快照（ADR-026 §决策 6 + Stage F）。
    public struct ListenerSnapshot: Decodable, Sendable, Identifiable {
        public var id: String { "\(addr):\(port)" }
        public let addr: String
        public let port: UInt16
        public let providerId: String
        public let `protocol`: String

        enum CodingKeys: String, CodingKey {
            case addr, port
            case providerId = "provider_id"
            case `protocol`
        }
    }

    public struct AuditDbSnapshot: Decodable, Sendable {
        public let path: String
        public let sizeBytes: UInt64
        public let schemaVersion: UInt32
        public let eventsTotal: UInt64
        public let eventsToday: UInt64

        enum CodingKeys: String, CodingKey {
            case path
            case sizeBytes = "size_bytes"
            case schemaVersion = "schema_version"
            case eventsTotal = "events_total"
            case eventsToday = "events_today"
        }
    }

    public struct RulesSnapshot: Decodable, Sendable {
        public let systemCount: UInt32
        public let userCount: UInt32
        public let lastReload: Date?

        enum CodingKeys: String, CodingKey {
            case systemCount = "system_count"
            case userCount = "user_count"
            case lastReload = "last_reload"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            systemCount = try c.decode(UInt32.self, forKey: .systemCount)
            userCount = try c.decode(UInt32.self, forKey: .userCount)
            lastReload = try Self.decodeISO8601(c, key: .lastReload)
        }

        private static func decodeISO8601(_ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> Date? {
            guard let s = try c.decodeIfPresent(String.self, forKey: key) else { return nil }
            return HealthResultDTO.parseISO8601(s)
        }
    }

    public struct GraylistSnapshot: Decodable, Sendable {
        public let activeCount: UInt32

        enum CodingKeys: String, CodingKey { case activeCount = "active_count" }
    }

    public struct IpcSnapshot: Decodable, Sendable {
        public let connectedClients: UInt32
        public let totalDecisionsInflight: UInt32

        enum CodingKeys: String, CodingKey {
            case connectedClients = "connected_clients"
            case totalDecisionsInflight = "total_decisions_inflight"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daemonVersion = try c.decode(String.self, forKey: .daemonVersion)
        protocolVersion = try c.decode(String.self, forKey: .protocolVersion)
        uptimeSeconds = try c.decode(UInt64.self, forKey: .uptimeSeconds)
        preset = try c.decode(PresetSnapshot.self, forKey: .preset)
        paused = try c.decode(Bool.self, forKey: .paused)
        listen = try c.decode(ListenSnapshot.self, forKey: .listen)
        // listeners 自 v2.x 起新增；旧 daemon 不发此字段时退化为空数组，
        // 调用方应回落到 listen 单值展示。
        listeners = try c.decodeIfPresent([ListenerSnapshot].self, forKey: .listeners) ?? []
        auditDb = try c.decode(AuditDbSnapshot.self, forKey: .auditDb)
        rules = try c.decode(RulesSnapshot.self, forKey: .rules)
        graylist = try c.decode(GraylistSnapshot.self, forKey: .graylist)
        ipc = try c.decode(IpcSnapshot.self, forKey: .ipc)

        let startedAtStr = try c.decode(String.self, forKey: .startedAt)
        guard let startedAtDate = Self.parseISO8601(startedAtStr) else {
            throw DecodingError.dataCorruptedError(
                forKey: .startedAt, in: c,
                debugDescription: "started_at is not a valid ISO8601 date: \(startedAtStr)")
        }
        startedAt = startedAtDate

        if let pausedUntilStr = try c.decodeIfPresent(String.self, forKey: .pausedUntil) {
            pausedUntil = Self.parseISO8601(pausedUntilStr)
        } else {
            pausedUntil = nil
        }
    }

    /// 解析 SPEC-005 §4A 约束的 RFC 3339 时间戳（毫秒精度 + Z 后缀）。
    fileprivate static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// 优先返回 `listeners`；空时回落 `listen` 派生单元素数组（旧 daemon 兼容路径）。
    public var effectiveListeners: [ListenerSnapshot] {
        if !listeners.isEmpty { return listeners }
        return [ListenerSnapshot(
            addr: listen.addr, port: listen.port,
            providerId: "(legacy)", protocol: "(legacy)")]
    }
}

