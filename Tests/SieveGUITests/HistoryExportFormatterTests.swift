import Testing
import Foundation
@testable import SieveGUICore

@Suite("HistoryExportFormatter — CSV/NDJSON 格式 + 脱敏正确性")
struct HistoryExportFormatterTests {

    private func makeRow(
        id: Int64 = 1,
        ruleId: String = "OUT-07",
        disposition: String = "gui_popup",
        userChoice: String? = "deny",
        evidenceMetaJSON: String? = "{\"secret\":\"BIP39-word-list\"}",
        fingerprint: String? = "fp_abc",
        sessionId: String? = "sess_xyz",
        callerPid: Int? = 1234,
        callerExe: String? = "/usr/bin/claude",
        requestId: String? = "req-001"
    ) -> AuditEventRow {
        AuditEventRow(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_746_000_000),
            direction: .outbound,
            severity: .high,
            ruleId: ruleId,
            disposition: disposition,
            userChoice: userChoice,
            fingerprint: fingerprint,
            sessionId: sessionId,
            callerPid: callerPid,
            callerExe: callerExe,
            evidenceMetaJSON: evidenceMetaJSON,
            requestId: requestId
        )
    }

    // MARK: - 脱敏验证

    @Test("CSV 行不包含 evidenceMetaJSON（红线）")
    func csv_does_not_contain_evidence() {
        let formatter = HistoryExportFormatter(format: .csv)
        let line = formatter.formatLine(row: makeRow(evidenceMetaJSON: "{\"secret\":\"BIP39-word-list\"}"))
        #expect(!line.contains("BIP39"))
        #expect(!line.contains("evidence"))
    }

    @Test("NDJSON 行不包含 evidenceMetaJSON（红线）")
    func ndjson_does_not_contain_evidence() {
        let formatter = HistoryExportFormatter(format: .ndjson)
        let line = formatter.formatLine(row: makeRow(evidenceMetaJSON: "{\"secret\":\"BIP39-word-list\"}"))
        #expect(!line.contains("BIP39"))
        #expect(!line.contains("evidence_meta"))
    }

    @Test("CSV 行不包含 fingerprint / session_id / caller_pid / caller_exe")
    func csv_does_not_contain_sensitive_fields() {
        let formatter = HistoryExportFormatter(format: .csv)
        let line = formatter.formatLine(row: makeRow())
        #expect(!line.contains("fp_abc"))
        #expect(!line.contains("sess_xyz"))
        #expect(!line.contains("1234"))
        #expect(!line.contains("claude"))
    }

    @Test("NDJSON 行不包含敏感字段")
    func ndjson_does_not_contain_sensitive_fields() {
        let formatter = HistoryExportFormatter(format: .ndjson)
        let line = formatter.formatLine(row: makeRow())
        #expect(!line.contains("fingerprint"))
        #expect(!line.contains("session_id"))
        #expect(!line.contains("caller_pid"))
        #expect(!line.contains("caller_exe"))
    }

    // MARK: - 格式正确性

    @Test("CSV 行包含 rule_id / direction / severity / disposition / user_choice / request_id")
    func csv_contains_expected_fields() {
        let formatter = HistoryExportFormatter(format: .csv)
        let line = formatter.formatLine(row: makeRow())
        #expect(line.contains("OUT-07"))
        #expect(line.contains("outbound"))
        #expect(line.contains("high"))
        #expect(line.contains("gui_popup"))
        #expect(line.contains("deny"))
        #expect(line.contains("req-001"))
    }

    @Test("NDJSON 行是合法 JSON 对象（包含基本字段）")
    func ndjson_valid_json_object() throws {
        let formatter = HistoryExportFormatter(format: .ndjson)
        let line = formatter.formatLine(row: makeRow())
        let data = line.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj != nil)
        #expect(obj?["rule_id"] as? String == "OUT-07")
        #expect(obj?["direction"] as? String == "outbound")
        #expect(obj?["severity"] as? String == "high")
        #expect(obj?["user_choice"] as? String == "deny")
        #expect(obj?["request_id"] as? String == "req-001")
    }

    @Test("CSV 生成含 header 行")
    func csv_generate_has_header() {
        let formatter = HistoryExportFormatter(format: .csv)
        let output = formatter.generate(rows: [makeRow()])
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.first?.hasPrefix("id,created_at") == true)
        #expect(lines.count == 2)  // header + 1 row
    }

    @Test("NDJSON 生成无 header 行（纯数据行）")
    func ndjson_generate_no_header() {
        let formatter = HistoryExportFormatter(format: .ndjson)
        let output = formatter.generate(rows: [makeRow(id: 1), makeRow(id: 2)])
        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(lines.first?.hasPrefix("{") == true)
    }

    @Test("CSV 特殊字符（逗号、引号）正确转义")
    func csv_escapes_special_chars() {
        let formatter = HistoryExportFormatter(format: .csv)
        let row = makeRow(ruleId: "rule,with,commas", disposition: "has\"quote")
        let line = formatter.formatLine(row: row)
        #expect(line.contains("\"rule,with,commas\""))
        #expect(line.contains("\"has\"\"quote\""))
    }
}
