import Foundation

/// 历史记录导出格式
public enum ExportFormat: String, CaseIterable, Sendable {
    case csv = "CSV"
    case ndjson = "NDJSON"

    public var fileExtension: String {
        switch self {
        case .csv: "csv"
        case .ndjson: "ndjson"
        }
    }
}

/// 历史导出脱敏格式化（红线：不含 evidence_meta / session_id / caller_pid / caller_exe 完整路径）
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
            lines.append(Self.csvHeader)
        }
        for row in rows {
            lines.append(formatLine(row: row, iso: iso))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static let csvHeader = "timestamp,direction,severity,rule_id,disposition,user_choice,fingerprint,caller_exe_basename"

    /// 单行格式化（脱敏）
    public func formatLine(row: AuditEventRow) -> String {
        formatLine(row: row, iso: makeISO())
    }

    private func formatLine(row: AuditEventRow, iso: ISO8601DateFormatter) -> String {
        let ts = iso.string(from: row.createdAt)
        let fingerprint = maskFingerprint(row.fingerprint)
        let callerExeBasename = row.callerExe.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        switch format {
        case .csv:
            return [
                ts,
                row.direction.rawValue,
                row.severity.rawValue,
                csvEscape(row.ruleId),
                csvEscape(row.disposition),
                csvEscape(row.userChoice ?? ""),
                csvEscape(fingerprint),
                csvEscape(callerExeBasename)
            ].joined(separator: ",")
        case .ndjson:
            var dict: [String: String] = [
                "timestamp": ts,
                "direction": row.direction.rawValue,
                "severity": row.severity.rawValue,
                "rule_id": row.ruleId,
                "disposition": row.disposition
            ]
            if let uc = row.userChoice { dict["user_choice"] = uc }
            if !fingerprint.isEmpty { dict["fingerprint"] = fingerprint }
            if !callerExeBasename.isEmpty { dict["caller_exe"] = callerExeBasename }
            // evidence_meta / session_id / caller_pid / caller_exe 完整路径 / request_id → 强制不写入
            // 用 JSONSerialization 生成，保证 value 中的引号 / 反斜杠 / 换行 / 控制字符被正确
            // 转义；手工拼字符串会在 value 含特殊字符时产出非法 JSON 甚至被注入伪造字段。
            // .sortedKeys 保持 key 顺序确定（与旧版按 key 排序一致）。
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8)
            {
                return json
            }
            return "{}"
        }
    }

    private func maskFingerprint(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        if value.count <= 8 { return value }
        return "\(value.prefix(4))...\(value.suffix(4))"
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
