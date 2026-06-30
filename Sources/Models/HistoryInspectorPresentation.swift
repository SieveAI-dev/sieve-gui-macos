import Foundation

public struct HistoryInspectorPresentation: Sendable, Equatable {
    public static let emptyValue = "—"

    public let fingerprintText: String
    public let sessionIdText: String
    public let callerPidText: String
    public let callerExeBasename: String
    public let evidenceMetaText: String

    public init(row: AuditEventRow, contentUnlocked: Bool) {
        fingerprintText = Self.maskFingerprint(row.fingerprint, contentUnlocked: contentUnlocked)
        sessionIdText = Self.maskSession(row.sessionId, contentUnlocked: contentUnlocked)
        callerPidText = Self.maskCallerPid(row.callerPid, contentUnlocked: contentUnlocked)
        callerExeBasename = Self.callerExeBasename(row.callerExe)
        evidenceMetaText = contentUnlocked
            ? (row.evidenceMetaJSON ?? Self.emptyValue)
            : Self.redactedEvidenceMeta(row.evidenceMetaJSON)
    }

    public static func maskFingerprint(_ value: String?, contentUnlocked: Bool) -> String {
        guard let value, !value.isEmpty else { return emptyValue }
        guard !contentUnlocked else { return value }
        guard value.count > 8 else { return String(repeating: "•", count: 8) }
        return "\(value.prefix(4))••••\(value.suffix(4))"
    }

    public static func maskSession(_ value: String?, contentUnlocked: Bool) -> String {
        guard let value, !value.isEmpty else { return emptyValue }
        guard !contentUnlocked else { return value }
        return value.count > 8 ? "\(value.prefix(8))…" : value
    }

    public static func maskCallerPid(_ value: Int?, contentUnlocked: Bool) -> String {
        guard let value else { return emptyValue }
        return contentUnlocked ? "\(value)" : String(repeating: "•", count: 8)
    }

    public static func callerExeBasename(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return emptyValue }
        return URL(fileURLWithPath: value).lastPathComponent
    }

    public static func redactedEvidenceMeta(_ raw: String?) -> String {
        guard let raw, let data = raw.data(using: .utf8), !raw.isEmpty else { return emptyValue }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return String(repeating: "•", count: 8)
        }
        let redacted = redactEvidenceObject(object)
        guard JSONSerialization.isValidJSONObject(redacted),
              let output = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: output, encoding: .utf8)
        else {
            return String(repeating: "•", count: 8)
        }
        return text
    }

    private static func redactEvidenceObject(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var redacted: [String: Any] = [:]
            for (key, rawValue) in dict {
                redacted[key] = isSensitiveEvidenceKey(key) ? "••••••••" : redactEvidenceObject(rawValue)
            }
            return redacted
        }
        if let array = value as? [Any] {
            return array.map(redactEvidenceObject)
        }
        return value
    }

    private static func isSensitiveEvidenceKey(_ key: String) -> Bool {
        let normalized = key.lowercased()
        return normalized == "prefix_hash" ||
            normalized == "suffix_hash" ||
            normalized == "session_id" ||
            normalized == "caller_pid" ||
            normalized == "caller_exe" ||
            normalized == "request_id" ||
            normalized.hasSuffix("_hash")
    }
}
