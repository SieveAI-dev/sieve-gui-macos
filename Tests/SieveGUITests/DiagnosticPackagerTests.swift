import Testing
import Foundation
import SQLite3
@testable import SieveGUICore

/// DiagnosticPackager audit.db 脱敏拷贝逻辑验证
/// 直接调用真实 DiagnosticPackager.copyAuditDBRedacted，避免测试逻辑和实现漂移。
@Suite("DiagnosticPackager — audit.db 脱敏拷贝")
struct DiagnosticPackagerTests {

    /// 创建含 evidence_meta 等敏感列的临时 audit.db
    private func makeTempAuditDB() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_audit_\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(tmp.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let create = """
        CREATE TABLE events (
            id INTEGER PRIMARY KEY,
            created_at TEXT,
            rule_id TEXT,
            direction TEXT,
            severity TEXT,
            disposition TEXT,
            evidence_meta TEXT,
            fingerprint TEXT,
            session_id TEXT,
            caller_pid INTEGER,
            caller_exe TEXT
        )
        """
        #expect(sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK)

        let insert = """
        INSERT INTO events VALUES
          (1,'2026-01-01T00:00:00Z','OUT-07','outbound','high','gui_popup',
           'BIP39: abandon ability able','fp_secret_123','sess_abc',9999,'/usr/bin/claude')
        """
        #expect(sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK)
        return tmp
    }

    /// 创建当前 daemon v3 audit_events schema 的临时 audit.db。
    private func makeTempAuditEventsDB() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_audit_v3_\(UUID().uuidString).db")
        var db: OpaquePointer?
        #expect(sqlite3_open(tmp.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let create = """
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
            provider_id TEXT NOT NULL DEFAULT 'unknown',
            fingerprint TEXT,
            session_id TEXT
        )
        """
        #expect(sqlite3_exec(db, create, nil, nil, nil) == SQLITE_OK)

        let insert = """
        INSERT INTO audit_events
        (timestamp_rfc3339, direction, rule_id, severity, disposition, decision,
         request_id, raw_json, caller_pid, caller_exe, provider_id, fingerprint, session_id)
        VALUES
        ('2026-01-01T00:00:00Z', 'inbound', 'IN-CR-05-EVM', 'critical', 'blocked', 'Block',
         'req-1', '{"secret":"BIP39 abandon ability able"}', 9999, '/usr/bin/claude',
         'anthropic', 'fp_secret_123', 'sess_abc')
        """
        #expect(sqlite3_exec(db, insert, nil, nil, nil) == SQLITE_OK)
        return tmp
    }

    @Test("audit.db 拷贝后 evidence 列全空")
    func redacted_copy_clears_evidence_columns() async throws {
        let src = try makeTempAuditDB()
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_audit_redacted_\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        }

        #expect(await DiagnosticPackager.shared.copyAuditDBRedacted(src: src.path, dst: dst.path))

        var db: OpaquePointer?
        #expect(sqlite3_open(dst.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        // 验证敏感列已清空
        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT evidence_meta, fingerprint, session_id, caller_exe FROM events", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let evidenceMeta = sqlite3_column_text(stmt, 0).map(String.init(cString:)) ?? ""
            let fingerprint = sqlite3_column_text(stmt, 1).map(String.init(cString:)) ?? ""
            let sessionId = sqlite3_column_text(stmt, 2).map(String.init(cString:)) ?? ""
            let callerExe = sqlite3_column_text(stmt, 3).map(String.init(cString:)) ?? ""
            #expect(evidenceMeta.isEmpty, "evidence_meta 应为空")
            #expect(!evidenceMeta.contains("BIP39"), "evidence 原文不得出现在导出文件")
            #expect(fingerprint.isEmpty, "fingerprint 应为空")
            #expect(sessionId.isEmpty, "session_id 应为空")
            #expect(callerExe.isEmpty, "caller_exe 应为空")
        }
    }

    @Test("audit.db schema 完整：脱敏后表结构不丢失")
    func redacted_copy_schema_intact() async throws {
        let src = try makeTempAuditDB()
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_audit_schema_\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        }

        #expect(await DiagnosticPackager.shared.copyAuditDBRedacted(src: src.path, dst: dst.path))

        var db: OpaquePointer?
        #expect(sqlite3_open(dst.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        // 表应存在
        var stmt: OpaquePointer?
        let checkTable = "SELECT name FROM sqlite_master WHERE type='table' AND name='events'"
        #expect(sqlite3_prepare_v2(db, checkTable, -1, &stmt, nil) == SQLITE_OK)
        #expect(sqlite3_step(stmt) == SQLITE_ROW, "events 表应在拷贝后存在")
        sqlite3_finalize(stmt)

        // 非敏感列应仍有数据
        var stmt2: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT rule_id, direction FROM events", -1, &stmt2, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt2) }
        #expect(sqlite3_step(stmt2) == SQLITE_ROW, "events 表应有行数据")
        let ruleId = sqlite3_column_text(stmt2, 0).map(String.init(cString:)) ?? ""
        let direction = sqlite3_column_text(stmt2, 1).map(String.init(cString:)) ?? ""
        #expect(ruleId == "OUT-07")
        #expect(direction == "outbound")
    }

    @Test("v3 audit_events schema：脱敏后保留审计表并清空敏感列")
    func redacted_copy_supports_v3_audit_events_schema() async throws {
        let src = try makeTempAuditEventsDB()
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_audit_v3_redacted_\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        }

        #expect(await DiagnosticPackager.shared.copyAuditDBRedacted(src: src.path, dst: dst.path))

        var db: OpaquePointer?
        #expect(sqlite3_open(dst.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT rule_id, raw_json, fingerprint, session_id, caller_pid, caller_exe FROM audit_events", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        #expect(sqlite3_step(stmt) == SQLITE_ROW, "audit_events 表应保留原行")

        let ruleId = sqlite3_column_text(stmt, 0).map(String.init(cString:)) ?? ""
        let rawJSON = sqlite3_column_text(stmt, 1).map(String.init(cString:)) ?? ""
        let fingerprint = sqlite3_column_text(stmt, 2).map(String.init(cString:)) ?? ""
        let sessionId = sqlite3_column_text(stmt, 3).map(String.init(cString:)) ?? ""
        let callerPid = sqlite3_column_text(stmt, 4).map(String.init(cString:)) ?? ""
        let callerExe = sqlite3_column_text(stmt, 5).map(String.init(cString:)) ?? ""

        #expect(ruleId == "IN-CR-05-EVM")
        #expect(rawJSON.isEmpty, "v3 raw_json 承载 evidence 元数据，诊断包必须清空")
        #expect(fingerprint.isEmpty)
        #expect(sessionId.isEmpty)
        #expect(callerPid.isEmpty)
        #expect(callerExe.isEmpty)
    }
}
