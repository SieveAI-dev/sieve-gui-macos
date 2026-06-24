import Foundation
import os.log
import SQLite3

/// 导出诊断包。强制脱敏。
/// 不提供"明文导出"选项。
public actor DiagnosticPackager {
    public static let shared = DiagnosticPackager()
    private let logger = Logger(subsystem: "com.sieve.gui", category: "diagnostic")

    /// 排除字段：prefix_hash / suffix_hash / session_id / caller_pid / caller_exe完整路径 / evidence_meta 原文
    public static let redactedFields: Set<String> = [
        "prefix_hash", "suffix_hash", "session_id",
        "caller_pid", "caller_exe", "evidence_meta",
        "fingerprint"
    ]

    /// audit.db 脱敏时清空的列（evidence 内容不得导出）
    public static let auditRedactedColumns: Set<String> = [
        "evidence_meta", "fingerprint", "session_id", "caller_pid", "caller_exe"
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
    /// 方法：用 SQLite3 API 复制整个 DB 文件，再对 events 表的脱敏列执行 UPDATE SET col = ''。
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

        // 获取 events 表实际存在的列
        let existingCols = getTableColumns(db: db, table: "events")
        let colsToRedact = DiagnosticPackager.auditRedactedColumns.filter { existingCols.contains($0) }
        guard !colsToRedact.isEmpty else { return true }  // 没有敏感列则直接返回成功

        let setClauses = colsToRedact.map { "\($0) = ''" }.joined(separator: ", ")
        let sql = "UPDATE events SET \(setClauses)"
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            logger.error("audit.db redact UPDATE failed")
            return false
        }
        return true
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
