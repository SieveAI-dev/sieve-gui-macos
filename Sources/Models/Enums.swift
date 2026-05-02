import Foundation

public enum Severity: String, Codable, CaseIterable, Sendable, Comparable {
    case critical, high, medium, low

    public var sortOrder: Int {
        switch self {
        case .critical: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

public enum Direction: String, Codable, CaseIterable, Sendable {
    case inbound, outbound
}

public enum Disposition: String, Codable, CaseIterable, Sendable {
    case guiPopup = "gui_popup"
    case autoRedact = "auto_redact"
    case statusBar = "status_bar"
    case hookTerminal = "hook_terminal"
    case other
}

public enum DefaultOnTimeout: String, Codable, Sendable {
    case block = "block"
    case allow = "allow"
    case redact = "redact"
}

public enum Decision: String, Codable, Sendable {
    case allow, deny
}

public enum RecommendationConfidence: String, Codable, Sendable {
    case high, medium, low
}

public enum Preset: String, Codable, CaseIterable, Sendable {
    case strict = "strict"
    case standard = "standard"
    case relaxed = "relaxed"
    case custom = "custom"
}

public enum NotifyKind: String, Codable, Sendable {
    case sequenceHit = "sequence_hit"
    case outboundRedacted = "outbound_redacted"
    case hookTerminal = "hook_terminal"
    case userRulesLoadFailed = "user_rules_load_failed"
    case userRulesReloaded = "user_rules_reloaded"
    case generic = "generic"
}

public enum HipsPhase: Sendable {
    case blue   // remaining/total > 0.5
    case orange // 0.2 < remaining/total <= 0.5
    case red    // remaining/total <= 0.2
}

public enum DaemonStatus: Equatable, Sendable {
    case normal
    case warning
    case hold
    case paused(until: Date)
    case disconnected(reason: DisconnectReason)

    public enum DisconnectReason: String, Sendable {
        case socketMissing = "socket_missing"
        case heartbeatTimeout = "heartbeat_timeout"
        case versionMismatch = "version_mismatch"
        case daemonShutdown = "daemon_shutdown"
        case unknown
    }
}
