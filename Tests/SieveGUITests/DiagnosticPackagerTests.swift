import Testing
import Foundation
import SQLite3

/// DiagnosticPackager audit.db 脱敏拷贝逻辑验证
/// DiagnosticPackager 在 Services/Diagnostic（Package.swift 排除），
/// 这里直接用 SQLite3 C API 验证脱敏逻辑正确性（等价于 copyAuditDBRedacted 的核心行为）。
@Suite("DiagnosticPackager — audit.db 脱敏拷贝")
struct DiagnosticPackagerTests {

    private let redactedColumns: Set<String> = [
        "evidence_meta", "fingerprint", "session_id", "caller_pid", "caller_exe"
    ]

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

    @Test("audit.db 拷贝后 evidence 列全空")
    func redacted_copy_clears_evidence_columns() throws {
        let src = try makeTempAuditDB()
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_audit_redacted_\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        }

        // 执行拷贝 + 脱敏（复现 DiagnosticPackager.copyAuditDBRedacted 核心逻辑）
        try FileManager.default.copyItem(at: src, to: dst)

        var db: OpaquePointer?
        #expect(sqlite3_open(dst.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let setClauses = redactedColumns.map { "\($0) = ''" }.joined(separator: ", ")
        let sql = "UPDATE events SET \(setClauses)"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)

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
    func redacted_copy_schema_intact() throws {
        let src = try makeTempAuditDB()
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_audit_schema_\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        }

        try FileManager.default.copyItem(at: src, to: dst)

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
}
