import Foundation

/// 历史记录导出格式
public enum ExportFormat: String, CaseIterable, Sendable {
    case csv = "CSV"
    case ndjson = "NDJSON"

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .ndjson: return "ndjson"
        }
    }
}

/// 历史导出脱敏格式化（ADR-011 红线：不含 evidence_meta / fingerprint / session_id / caller_pid / caller_exe）
/// 纯函数，无副作用，可单元测试。
public struct HistoryExportFormatter: Sendable {
    public let format: ExportFormat

    public init(format: ExportFormat) {
        self.format = format
    }

    private func makeISO() -> ISO8601DateFormatter {
        ISO8601DateFormatter()
    }

    /// 生成导出内容（完整字符串）
    public func generate(rows: [AuditEventRow]) -> String {
        let iso = makeISO()
        var lines: [String] = []
        if format == .csv {
            lines.append("id,created_at,direction,severity,rule_id,disposition,user_choice,request_id")
        }
        for row in rows {
            lines.append(formatLine(row: row, iso: iso))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 单行格式化（脱敏）
    public func formatLine(row: AuditEventRow) -> String {
        formatLine(row: row, iso: makeISO())
    }

    private func formatLine(row: AuditEventRow, iso: ISO8601DateFormatter) -> String {
        let ts = iso.string(from: row.createdAt)
        switch format {
        case .csv:
            return [
                "\(row.id)",
                ts,
                row.direction.rawValue,
                row.severity.rawValue,
                csvEscape(row.ruleId),
                csvEscape(row.disposition),
                csvEscape(row.userChoice ?? ""),
                csvEscape(row.requestId ?? "")
            ].joined(separator: ",")
        case .ndjson:
            var dict: [String: String] = [
                "id": "\(row.id)",
                "created_at": ts,
                "direction": row.direction.rawValue,
                "severity": row.severity.rawValue,
                "rule_id": row.ruleId,
                "disposition": row.disposition
            ]
            if let uc = row.userChoice { dict["user_choice"] = uc }
            if let rid = row.requestId { dict["request_id"] = rid }
            // evidence_meta / fingerprint / session_id / caller_pid / caller_exe → 强制不写入（ADR-011）
            let pairs = dict.sorted(by: { $0.key < $1.key })
                .map { "\"\($0.key)\":\"\($0.value)\"" }
                .joined(separator: ",")
            return "{\(pairs)}"
        }
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
