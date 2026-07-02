import Foundation
import SQLite3
import Testing
@testable import SieveGUICore

/// 直接驱动真实 AuditDBReader（非复现逻辑）覆盖：
/// - v2 完整 schema 读取正确
/// - schemaWarning：user_version 未知 → true；已知（1/2）→ false
/// - 增量读取 incrementalEvents(sinceId:) 只返回新行
/// - fail-soft：v1 旧 schema（缺 v2 列）不崩溃
///
/// AuditDBReader.open(path:) 支持路径注入；本套件用独立临时 db 路径经 open(path:)
/// 注入，不依赖 dbPath/HOME，永不触碰用户真实 ~/.sieve/audit.db。
@Suite("AuditDBReader — 真实只读 reader 覆盖", .serialized)
struct AuditDBReaderTests {
    // MARK: - 临时 db 路径（经 open(path:) 注入）

    /// 每次调用返回独立临时 db 路径。测试经 `reader.open(path:)` 注入，不依赖
    /// AuditDBReader.dbPath / HOME，杜绝误写用户真实 audit.db。
    private func resolvedDBPath() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sieve_audit_reader_test_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("audit.db").path
    }

    // MARK: - Fixture 构造

    /// v2 完整 schema：含 caller_pid / caller_exe / evidence_meta / request_id 等列。
    private func createV2Schema(at path: String, userVersion: Int = 2) throws {
        try removeIfExists(path)
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw FixtureError.openFailed }
        defer { sqlite3_close(db) }
        try exec(db, "PRAGMA user_version = \(userVersion)")
        try exec(db, """
        CREATE TABLE events (
            id INTEGER PRIMARY KEY,
            created_at TEXT,
            direction TEXT,
            severity TEXT,
            rule_id TEXT,
            disposition TEXT,
            user_choice TEXT,
            fingerprint TEXT,
            session_id TEXT,
            caller_pid INTEGER,
            caller_exe TEXT,
            evidence_meta TEXT,
            request_id TEXT
        )
        """)
    }

    /// 当前 daemon v3 schema：表名 audit_events，时间列 timestamp_rfc3339，decision/raw_json。
    private func createV3AuditEventsSchema(at path: String, userVersion: Int = 3) throws {
        try removeIfExists(path)
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw FixtureError.openFailed }
        defer { sqlite3_close(db) }
        try exec(db, "PRAGMA user_version = \(userVersion)")
        try exec(db, """
        CREATE TABLE audit_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp_rfc3339 TEXT NOT NULL,
            direction TEXT NOT NULL,
            rule_id TEXT NOT NULL,
            severity TEXT NOT NULL,
            disposition TEXT NOT NULL,
            decision TEXT,
            request_id TEXT NOT NULL,
            raw_json TEXT,
            caller_pid INTEGER,
            caller_exe TEXT,
            provider_id TEXT NOT NULL DEFAULT 'unknown'
        )
        """)
    }

    /// v1 旧 schema：缺少 v2 才有的 caller_pid / caller_exe 列（fail-soft 路径）。
    private func createV1Schema(at path: String, userVersion: Int = 1) throws {
        try removeIfExists(path)
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw FixtureError.openFailed }
        defer { sqlite3_close(db) }
        try exec(db, "PRAGMA user_version = \(userVersion)")
        try exec(db, """
        CREATE TABLE events (
            id INTEGER PRIMARY KEY,
            created_at TEXT,
            direction TEXT,
            severity TEXT,
            rule_id TEXT,
            disposition TEXT,
            user_choice TEXT,
            fingerprint TEXT,
            session_id TEXT,
            evidence_meta TEXT,
            request_id TEXT
        )
        """)
    }

    /// 向 v2 表插入一行（列齐全）。
    private func insertV2Row(
        at path: String,
        id: Int,
        ruleId: String = "IN-CR-01",
        direction: String = "inbound",
        severity: String = "high",
        fingerprint: String? = nil,
        callerPid: Int = 4242,
        callerExe: String = "/usr/bin/claude"
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw FixtureError.openFailed }
        defer { sqlite3_close(db) }
        try exec(db, """
        INSERT INTO events
        (id, created_at, direction, severity, rule_id, disposition, user_choice,
         fingerprint, session_id, caller_pid, caller_exe, evidence_meta, request_id)
        VALUES
        (\(id), '2026-01-01T00:00:0\(id % 10)Z', '\(direction)', '\(severity)', '\(ruleId)',
         'gui_popup', 'deny', '\(fingerprint ?? "fp_\(id)")', 'sess_\(id)', \(callerPid), '\(callerExe)',
         '{"k":"v"}', 'req_\(id)')
        """)
    }

    private func insertV3AuditEventRow(
        at path: String,
        id: Int,
        ruleId: String = "IN-CR-05-EVM",
        direction: String = "inbound",
        severity: String = "Critical",
        decision: String = "Block"
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw FixtureError.openFailed }
        defer { sqlite3_close(db) }
        try exec(db, """
        INSERT INTO audit_events
        (id, timestamp_rfc3339, direction, rule_id, severity, disposition, decision,
         request_id, raw_json, caller_pid, caller_exe, provider_id)
        VALUES
        (\(id), '2026-01-01T00:00:0\(id % 10)Z', '\(direction)', '\(ruleId)', '\(severity)',
         'pending', '\(decision)', 'req_v3_\(id)', '{"tool":"eth_signTransaction"}',
         5150, '/usr/bin/codex', 'anthropic')
        """)
    }

    /// 向 v1 表插入一行（无 caller_pid / caller_exe 列）。
    private func insertV1Row(
        at path: String,
        id: Int,
        ruleId: String = "OUT-07",
        direction: String = "outbound",
        severity: String = "medium"
    ) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw FixtureError.openFailed }
        defer { sqlite3_close(db) }
        try exec(db, """
        INSERT INTO events
        (id, created_at, direction, severity, rule_id, disposition, user_choice,
         fingerprint, session_id, evidence_meta, request_id)
        VALUES
        (\(id), '2026-01-01T00:00:0\(id % 10)Z', '\(direction)', '\(severity)', '\(ruleId)',
         'auto_redact', NULL, 'fp_\(id)', 'sess_\(id)', '{"k":"v"}', 'req_\(id)')
        """)
    }

    // MARK: - 测试：v2 完整 schema 读取正确

    @Test("v2 完整 schema：recentEvents 字段映射正确，schemaWarning=false")
    func v2_schema_reads_correctly() throws {
        let path = resolvedDBPath()
        try createV2Schema(at: path)
        try insertV2Row(at: path, id: 1, ruleId: "IN-CR-01", direction: "inbound",
                        severity: "critical", callerPid: 1234, callerExe: "/usr/bin/claude")

        let reader = AuditDBReader()
        try reader.open(path: path)
        defer { reader.close() }

        #expect(reader.schemaVersion == 2)
        #expect(reader.schemaWarning == false, "已知 user_version=2 不应触发 schema 警告")

        let rows = reader.recentEvents(limit: 50)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.id == 1)
        #expect(row.ruleId == "IN-CR-01")
        #expect(row.direction == .inbound)
        #expect(row.severity == .critical)
        #expect(row.disposition == "gui_popup")
        #expect(row.userChoice == "deny")
        #expect(row.fingerprint == "fp_1")
        #expect(row.sessionId == "sess_1")
        #expect(row.callerPid == 1234, "v2 caller_pid 列应被读出")
        #expect(row.callerExe == "/usr/bin/claude", "v2 caller_exe 列应被读出")
        #expect(row.evidenceMetaJSON == "{\"k\":\"v\"}")
        #expect(row.requestId == "req_1")
    }

    @Test("v3 daemon schema：audit_events 表字段映射正确，schemaWarning=false")
    func v3_audit_events_schema_reads_correctly() throws {
        let path = resolvedDBPath()
        try createV3AuditEventsSchema(at: path)
        try insertV3AuditEventRow(at: path, id: 1)

        let reader = AuditDBReader()
        try reader.open(path: path)
        defer { reader.close() }

        #expect(reader.schemaVersion == 3)
        #expect(reader.schemaWarning == false, "当前 daemon user_version=3 不应触发 schema 警告")

        let rows = reader.recentEvents(limit: 50)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.id == 1)
        #expect(row.ruleId == "IN-CR-05-EVM")
        #expect(row.direction == .inbound)
        #expect(row.severity == .critical)
        #expect(row.disposition == "pending")
        #expect(row.userChoice == "deny")
        #expect(row.fingerprint == nil)
        #expect(row.sessionId == nil)
        #expect(row.callerPid == 5150)
        #expect(row.callerExe == "/usr/bin/codex")
        #expect(row.evidenceMetaJSON == #"{"tool":"eth_signTransaction"}"#)
        #expect(row.requestId == "req_v3_1")
    }

    @Test("event(requestId:) 精确返回匹配记录，不受最近分页位置影响")
    func event_by_request_id() throws {
        let path = resolvedDBPath()
        try createV2Schema(at: path)
        for i in 1 ... 5 {
            try insertV2Row(at: path, id: i)
        }

        let reader = AuditDBReader()
        try reader.open(path: path)
        defer { reader.close() }

        #expect(reader.event(requestId: "req_3")?.id == 3)
        #expect(reader.event(requestId: "missing") == nil)
    }

    // MARK: - 测试：schemaWarning 判定

    @Test("schemaWarning：未知 user_version（999）→ true")
    func unknown_user_version_triggers_warning() throws {
        let path = resolvedDBPath()
        try createV2Schema(at: path, userVersion: 999)
        try insertV2Row(at: path, id: 1)

        let reader = AuditDBReader()
        try reader.open(path: path)
        defer { reader.close() }

        #expect(reader.schemaVersion == 999)
        #expect(reader.schemaWarning == true, "未知 user_version 必须 fail-soft 触发 schema 警告")
        // 即便 schema 警告，已存在的标准列仍应可读（fail-soft，不阻断查询）
        #expect(reader.recentEvents(limit: 50).count == 1)
    }

    @Test("schemaWarning：已知 user_version=1 → false")
    func known_v1_user_version_no_warning() throws {
        let path = resolvedDBPath()
        try createV1Schema(at: path, userVersion: 1)
        try insertV1Row(at: path, id: 1)

        let reader = AuditDBReader()
        try reader.open(path: path)
        defer { reader.close() }

        #expect(reader.schemaVersion == 1)
        #expect(reader.schemaWarning == false, "已知 user_version=1 不应触发警告")
    }

    // MARK: - 测试：增量读取

    @Test("incrementalEvents(sinceId:) 仅返回 id > sinceId 的新行（ASC）")
    func incremental_returns_only_new_rows() throws {
        let path = resolvedDBPath()
        try createV2Schema(at: path)
        for i in 1 ... 5 {
            try insertV2Row(at: path, id: i)
        }

        let reader = AuditDBReader()
        try reader.open(path: path)
        defer { reader.close() }

        // sinceId=2 → 仅 3,4,5
        let delta = reader.incrementalEvents(sinceId: 2)
        #expect(delta.map(\.id) == [3, 4, 5], "增量应仅含 id>2 且按 ASC 排列")

        // sinceId=5（=最大）→ 空
        #expect(reader.incrementalEvents(sinceId: 5).isEmpty, "无新行时增量应为空")

        // sinceId=0 → 全量（ASC）
        #expect(reader.incrementalEvents(sinceId: 0).map(\.id) == [1, 2, 3, 4, 5])

        // maxId 应等于最大主键
        #expect(reader.maxId() == 5)
    }

    @Test("incrementalEvents 受 limit 约束，仍按 ASC 自低位起")
    func incremental_respects_limit() throws {
        let path = resolvedDBPath()
        try createV2Schema(at: path)
        for i in 1 ... 10 {
            try insertV2Row(at: path, id: i)
        }

        let reader = AuditDBReader()
        try reader.open(path: path)
        defer { reader.close() }

        let delta = reader.incrementalEvents(sinceId: 0, limit: 3)
        #expect(delta.map(\.id) == [1, 2, 3], "limit 应从 sinceId 之上最小 id 起取")
    }

    // MARK: - 测试：fail-soft（v1 旧 schema 缺列不崩溃）

    @Test("fail-soft：v1 旧 schema 缺 caller_pid/caller_exe 列，查询不崩溃且回填 nil")
    func v1_schema_missing_v2_columns_fail_soft() throws {
        let path = resolvedDBPath()
        try createV1Schema(at: path, userVersion: 1)
        try insertV1Row(at: path, id: 1, ruleId: "OUT-07", direction: "outbound", severity: "medium")

        let reader = AuditDBReader()
        try reader.open(path: path)
        defer { reader.close() }

        let rows = reader.recentEvents(limit: 50)
        #expect(rows.count == 1, "v1 schema 标准列仍应正常读出")
        let row = try #require(rows.first)
        #expect(row.ruleId == "OUT-07")
        #expect(row.direction == .outbound)
        #expect(row.severity == .medium)
        // v2 才有的列在 v1 表缺失 → fail-soft 回填 nil，不抛错
        #expect(row.callerPid == nil, "v1 表无 caller_pid，应 fail-soft 回填 nil")
        #expect(row.callerExe == nil, "v1 表无 caller_exe，应 fail-soft 回填 nil")
        // 增量路径同样不应在缺列时崩溃
        #expect(reader.incrementalEvents(sinceId: 0).count == 1)
    }

    @Test("recentEvents filter：按 direction/severity/keyword 过滤")
    func recent_events_filter_applies() throws {
        let path = resolvedDBPath()
        try createV2Schema(at: path)
        try insertV2Row(at: path, id: 1, ruleId: "IN-CR-01", direction: "inbound", severity: "high")
        try insertV2Row(at: path, id: 2, ruleId: "OUT-07", direction: "outbound", severity: "low")
        try insertV2Row(at: path, id: 3, ruleId: "IN-CR-02", direction: "inbound", severity: "high")

        let reader = AuditDBReader()
        try reader.open(path: path)
        defer { reader.close() }

        let inbound = reader.recentEvents(limit: 50, filter: .init(direction: .inbound))
        #expect(Set(inbound.map(\.id)) == [1, 3], "direction 过滤应仅留 inbound 行")

        let kw = reader.recentEvents(limit: 50, filter: .init(keyword: "OUT"))
        #expect(kw.map(\.id) == [2], "keyword 过滤应命中 rule_id 前缀")
    }

    @Test("recentEvents keyword：仅匹配 rule_id/fingerprint 前缀，且转义 LIKE 通配符")
    func keyword_matches_rule_or_fingerprint_prefix_only() throws {
        let path = resolvedDBPath()
        try createV2Schema(at: path)
        try insertV2Row(at: path, id: 1, ruleId: "IN-CR-01", fingerprint: "sha256:abc123")
        try insertV2Row(at: path, id: 2, ruleId: "X-IN-CR-02", fingerprint: "fp-middle")
        try insertV2Row(at: path, id: 3, ruleId: "OUT-07", fingerprint: "sha256:def456")
        try insertV2Row(at: path, id: 4, ruleId: "PERCENT%RULE", fingerprint: "literal_under_score")

        let reader = AuditDBReader()
        try reader.open(path: path)
        defer { reader.close() }

        #expect(reader.recentEvents(limit: 50, filter: .init(keyword: "IN-CR")).map(\.id) == [1])
        #expect(reader.recentEvents(limit: 50, filter: .init(keyword: "sha256:de")).map(\.id) == [3])
        #expect(reader.recentEvents(limit: 50, filter: .init(keyword: "%")).map(\.id).isEmpty)
        #expect(reader.recentEvents(limit: 50, filter: .init(keyword: "PERCENT%")).map(\.id) == [4])
        #expect(reader.recentEvents(limit: 50, filter: .init(keyword: "literal_")).map(\.id) == [4])
    }

    // MARK: - 辅助

    private func removeIfExists(_ path: String) throws {
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let msg = errmsg.map { ptr in String(cString: ptr) } ?? "unknown"
            sqlite3_free(errmsg)
            throw FixtureError.execFailed(msg)
        }
    }

    private enum FixtureError: Error {
        case openFailed
        case execFailed(String)
    }
}
