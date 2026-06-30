import Foundation
import os.log
import SQLite3

/// 导出诊断包。强制脱敏。
/// 不提供"明文导出"选项。
public actor DiagnosticPackager {
    public static let shared = DiagnosticPackager()
    private let logger = Logger(subsystem: "com.sieve.gui", category: "diagnostic")

    /// 排除字段：prefix_hash / suffix_hash / session_id / caller_pid / caller_exe完整路径 / evidence_meta/raw_json 原文
    public static let redactedFields: Set<String> = [
        "prefix_hash", "suffix_hash", "session_id",
        "caller_pid", "caller_exe", "evidence_meta", "raw_json",
        "fingerprint"
    ]

    /// audit.db 脱敏时清空的列（evidence 内容不得导出）
    public static let auditRedactedColumns: Set<String> = [
        "evidence_meta", "raw_json", "fingerprint", "session_id", "caller_pid", "caller_exe"
    ]

    public func exportRedacted() async -> URL? {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let outURL = downloads.appendingPathComponent("sieve-diagnostic-\(stamp).zip")

        // 1. 收集源文件
        let logSources: [URL] = [
            URL(fileURLWithPath: NSHomeDirectory() + "/.sieve/gui.log"),
            URL(fileURLWithPath: NSHomeDirectory() + "/.sieve/gui.log.1")
        ].filter { fm.fileExists(atPath: $0.path) }

        // 2. 创建临时目录，复制脱敏后的文件
        let tmpDir = fm.temporaryDirectory.appendingPathComponent("sieve-diag-\(UUID().uuidString)")
        try? fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        var includedFiles: [String] = []

        // 2a. gui.log 脱敏拷贝
        for src in logSources {
            let dst = tmpDir.appendingPathComponent(src.lastPathComponent)
            if let data = try? Data(contentsOf: src) {
                let red = redactLogData(data)
                try? red.write(to: dst)
                includedFiles.append(src.lastPathComponent)
            }
        }

        // 2b. audit.db 脱敏拷贝（清空 evidence 列，保留 schema + 元数据）
        let auditSrc = NSHomeDirectory() + "/.sieve/audit.db"
        if fm.fileExists(atPath: auditSrc) {
            let auditDst = tmpDir.appendingPathComponent("audit_redacted.db")
            if copyAuditDBRedacted(src: auditSrc, dst: auditDst.path) {
                includedFiles.append("audit_redacted.db")
            } else {
                logger.warning("audit.db redacted copy failed, skipping")
            }
        }

        // 3. 写 manifest.json
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let manifest: [String: Any] = [
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "gui_version": version,
            "included_files": includedFiles,
            "redacted_columns": Array(DiagnosticPackager.auditRedactedColumns).sorted(),
            "note": "本包已自动脱敏：evidence_meta / fingerprint / session_id / caller_pid / caller_exe 已清空"
        ]
        if let manifestData = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? manifestData.write(to: tmpDir.appendingPathComponent("manifest.json"))
        }

        // 4. 调用 ditto 打成 zip
        let proc = Process()
        proc.launchPath = "/usr/bin/ditto"
        proc.arguments = ["-c", "-k", "--keepParent", tmpDir.path, outURL.path]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0 ? outURL : nil
        } catch {
            logger.error("diagnostic zip failed")
            return nil
        }
    }

    /// 拷贝 audit.db 并将 evidence 列清空。
    /// 方法：用 SQLite3 API 复制整个 DB 文件，再对 audit_events/events 表的脱敏列执行 UPDATE SET col = ''。
    /// 返回：拷贝并脱敏是否成功。
    public func copyAuditDBRedacted(src: String, dst: String) -> Bool {
        // Step 1: 文件层面拷贝（保留 schema + 全量行）
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
            try fm.copyItem(atPath: src, toPath: dst)
        } catch {
            logger.error("audit.db copy failed")
            return false
        }

        // Step 2: 打开拷贝，UPDATE 清空 evidence 列
        var db: OpaquePointer?
        guard sqlite3_open(dst, &db) == SQLITE_OK else {
            logger.error("audit.db redacted open failed")
            return false
        }
        defer { sqlite3_close(db) }

        guard let auditTable = resolveAuditTable(db: db) else {
            logger.error("audit.db redact: audit_events/events 表不存在，拒绝导出未知 schema 的库")
            return false
        }

        // 获取实际审计表存在的列。
        let existingCols = getTableColumns(db: db, table: auditTable)
        // 审计表不存在（返回空集）= schema 不符预期。绝不能当作"无敏感列"放行——
        // 那会把一个结构未知、可能含未脱敏 evidence 的库原样塞进诊断包。拒绝导出。
        guard !existingCols.isEmpty else {
            logger.error("audit.db redact: 审计表无列信息，拒绝导出未知 schema 的库")
            return false
        }
        let colsToRedact = DiagnosticPackager.auditRedactedColumns.filter { existingCols.contains($0) }
        // 审计表存在但无任一敏感列 = 该 schema 本就不含 evidence，跳过 UPDATE。
        if !colsToRedact.isEmpty {
            let setClauses = colsToRedact.map { "\($0) = ''" }.joined(separator: ", ")
            let sql = "UPDATE \(auditTable) SET \(setClauses)"
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                logger.error("audit.db redact UPDATE failed")
                return false
            }
        }
        // VACUUM 回收被清空列占用的页，否则旧 evidence 明文残留在 SQLite freelist，
        // strings(1) 仍可从拷贝文件恢复——脱敏形同虚设。
        if sqlite3_exec(db, "VACUUM", nil, nil, nil) != SQLITE_OK {
            logger.error("audit.db redact VACUUM failed")
            return false
        }
        return true
    }

    private func resolveAuditTable(db: OpaquePointer?) -> String? {
        if tableExists(db: db, table: "audit_events") { return "audit_events" }
        if tableExists(db: db, table: "events") { return "events" }
        return nil
    }

    private func tableExists(db: OpaquePointer?, table: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name='\(table)' LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// 获取表的列名列表
    private func getTableColumns(db: OpaquePointer?, table: String) -> Set<String> {
        var cols = Set<String>()
        var stmt: OpaquePointer?
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return cols }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cName = sqlite3_column_text(stmt, 1) {
                cols.insert(String(cString: cName))
            }
        }
        return cols
    }

    /// 简单的字段名级别脱敏：把含敏感字段名的整行替换为 ••••。
    private func redactLogData(_ data: Data) -> Data {
        guard let s = String(data: data, encoding: .utf8) else { return data }
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        let redacted = lines.map { line -> String in
            for f in DiagnosticPackager.redactedFields {
                if line.contains(f) {
                    return "[REDACTED LINE — contained \(f)]"
                }
            }
            return String(line)
        }
        return redacted.joined(separator: "\n").data(using: .utf8) ?? data
    }
}
