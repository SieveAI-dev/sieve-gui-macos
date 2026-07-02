import Foundation
import os.log
import SQLite

/// 只读访问 ~/.sieve/audit.db。当前 daemon 表名是 audit_events；旧 GUI fixture 仍兼容 events。
/// 关键约束：
/// - 后台 DispatchQueue，不在 MainActor 执行查询
/// - 所有查询带 LIMIT
/// - schema user_version 未知 → fail-soft，banner 警告
public final class AuditDBReader: @unchecked Sendable {
    public static let knownUserVersions: Set<Int> = [1, 2, 3]
    public static let dbPath: String = NSHomeDirectory() + "/.sieve/audit.db"

    private let logger = Logger(subsystem: "com.sieve.gui", category: "audit-db")
    private let queue = DispatchQueue(label: "com.sieve.gui.audit-db", qos: .userInitiated)
    private var db: Connection?
    private var watcher: AuditDBFileWatcher?
    public private(set) var schemaVersion: Int = 0
    public var schemaWarning: Bool {
        !AuditDBReader.knownUserVersions.contains(schemaVersion)
    }

    private var events = Table("events")
    private let id = SQLite.Expression<Int64>("id")
    private var createdAt = SQLite.Expression<String>("created_at")
    private let direction = SQLite.Expression<String>("direction")
    private let severity = SQLite.Expression<String>("severity")
    private let ruleId = SQLite.Expression<String>("rule_id")
    private let disposition = SQLite.Expression<String>("disposition")
    private var userChoice = SQLite.Expression<String?>("user_choice")
    private var fingerprint = SQLite.Expression<String?>("__missing_fingerprint")
    private var hasFingerprintColumn = false
    private var sessionId = SQLite.Expression<String?>("__missing_session_id")
    private let callerPid = SQLite.Expression<Int?>("caller_pid")
    private let callerExe = SQLite.Expression<String?>("caller_exe")
    private var evidenceMeta = SQLite.Expression<String?>("evidence_meta")
    private let requestId = SQLite.Expression<String?>("request_id")

    public init() {}

    public func open(path: String = AuditDBReader.dbPath) throws {
        try queue.sync {
            guard FileManager.default.fileExists(atPath: path) else {
                throw AuditDBError.notFound(path: path)
            }
            db = try Connection(path, readonly: true)
            schemaVersion = (try? db?.scalar("PRAGMA user_version") as? Int64).flatMap(Int.init) ?? 0
            try configureSchema(db)
            logger.notice("audit.db opened, user_version=\(self.schemaVersion, privacy: .public)")
        }
    }

    public func close() {
        queue.sync {
            db = nil
            watcher?.stop()
            watcher = nil
        }
    }

    /// 增量查询：返回 id > sinceId 的新行（按 id ASC）。limit 上限 200。
    public func incrementalEvents(sinceId: Int64, limit: Int = 50) -> [AuditEventRow] {
        queue.sync {
            guard let db else { return [] }
            let q = events.filter(id > sinceId).order(id.asc).limit(min(limit, 200))
            return rows(from: db, query: q)
        }
    }

    /// 分页查询（历史窗口列表使用）。
    public func recentEvents(limit: Int = 50, offset: Int = 0, filter: AuditFilter = .init()) -> [AuditEventRow] {
        queue.sync {
            guard let db else { return [] }
            var q = events.order(id.desc)
            if let dir = filter.direction { q = q.filter(direction == dir.rawValue) }
            if let sev = filter.severity { q = q.filter(severity == sev.rawValue) }
            if let from = filter.fromDate {
                q = q.filter(createdAt >= ISO8601DateFormatter().string(from: from))
            }
            if let to = filter.toDate {
                q = q.filter(createdAt <= ISO8601DateFormatter().string(from: to))
            }
            if let kw = filter.keyword, !kw.isEmpty {
                let pattern = "\(escapeLike(kw))%"
                if hasFingerprintColumn {
                    q = q.filter(
                        ruleId.like(pattern, escape: "\\") ||
                            fingerprint.like(pattern, escape: "\\") == true
                    )
                } else {
                    q = q.filter(ruleId.like(pattern, escape: "\\"))
                }
            }
            q = q.limit(min(limit, 200), offset: offset)
            return rows(from: db, query: q)
        }
    }

    /// 按 request_id 精确定位历史记录。QuickMenu 最近命中跳转使用；最多返回一行。
    public func event(requestId value: String) -> AuditEventRow? {
        queue.sync {
            guard let db else { return nil }
            let q = events.filter(requestId == value).order(id.desc).limit(1)
            return rows(from: db, query: q).first
        }
    }

    public func maxId() -> Int64 {
        queue.sync {
            guard let db else { return 0 }
            return (try? db.scalar(events.select(id.max))) ?? 0
        }
    }

    public func startWatching(onChange: @escaping @Sendable () -> Void) {
        queue.sync {
            watcher?.stop()
            let w = AuditDBFileWatcher(path: AuditDBReader.dbPath, onChange: onChange)
            watcher = w
            w.start()
        }
    }

    private func rows(from db: Connection, query: Table) -> [AuditEventRow] {
        do {
            return try db.prepare(query).map { row in
                let dir = Direction(rawValue: row[direction].lowercased()) ?? .outbound
                let sev = Severity(rawValue: row[severity].lowercased()) ?? .low
                let dateString = row[createdAt]
                let date = parseISO8601(dateString) ?? Date()
                // v2 schema 字段 fail-soft：Row.get 在 column 缺失时抛错
                let pid: Int? = (try? row.get(callerPid)) ?? nil
                let exe: String? = (try? row.get(callerExe)) ?? nil
                let choice: String? = (try? row.get(userChoice))?.map { normalizeDecision($0) } ?? nil
                let fp: String? = (try? row.get(fingerprint)) ?? nil
                let sid: String? = (try? row.get(sessionId)) ?? nil
                let evidence: String? = (try? row.get(evidenceMeta)) ?? nil
                let reqId: String? = (try? row.get(requestId)) ?? nil
                return AuditEventRow(
                    id: row[id],
                    createdAt: date,
                    direction: dir,
                    severity: sev,
                    ruleId: row[ruleId],
                    disposition: row[disposition],
                    userChoice: choice,
                    fingerprint: fp,
                    sessionId: sid,
                    callerPid: pid,
                    callerExe: exe,
                    evidenceMetaJSON: evidence,
                    requestId: reqId
                )
            }
        } catch {
            logger.error("audit.db query failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    private func configureSchema(_ db: Connection?) throws {
        guard let db else { return }
        if try tableExists(db, name: "audit_events") {
            let columns = try tableColumns(db, table: "audit_events")
            events = Table("audit_events")
            createdAt = SQLite.Expression<String>("timestamp_rfc3339")
            userChoice = SQLite.Expression<String?>("decision")
            evidenceMeta = SQLite.Expression<String?>("raw_json")
            fingerprint = SQLite.Expression<String?>(
                columns.contains("fingerprint") ? "fingerprint" : "__missing_fingerprint"
            )
            hasFingerprintColumn = columns.contains("fingerprint")
            sessionId = SQLite.Expression<String?>(
                columns.contains("session_id") ? "session_id" : "__missing_session_id"
            )
            return
        }

        if try tableExists(db, name: "events") {
            let columns = try tableColumns(db, table: "events")
            events = Table("events")
            createdAt = SQLite.Expression<String>("created_at")
            userChoice = SQLite.Expression<String?>("user_choice")
            evidenceMeta = SQLite.Expression<String?>("evidence_meta")
            fingerprint = SQLite.Expression<String?>(
                columns.contains("fingerprint") ? "fingerprint" : "__missing_fingerprint"
            )
            hasFingerprintColumn = columns.contains("fingerprint")
            sessionId = SQLite.Expression<String?>(
                columns.contains("session_id") ? "session_id" : "__missing_session_id"
            )
        }
    }

    private func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func tableExists(_ db: Connection, name: String) throws -> Bool {
        let count = try db.scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
            name
        ) as! Int64
        return count > 0
    }

    private func tableColumns(_ db: Connection, table: String) throws -> Set<String> {
        var names = Set<String>()
        for row in try db.prepare("PRAGMA table_info(\(table))") {
            if let name = row[1] as? String {
                names.insert(name)
            }
        }
        return names
    }

    private func normalizeDecision(_ value: String) -> String {
        switch value.lowercased() {
        case "allow": "allow"
        case "block", "deny": "deny"
        default: value
        }
    }

    private func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

public enum AuditDBError: Error {
    case notFound(path: String)
    case schemaUnknown(version: Int)
}

public struct AuditFilter: Sendable, Equatable {
    public var direction: Direction?
    public var severity: Severity?
    public var fromDate: Date?
    public var toDate: Date?
    public var keyword: String?

    public init(direction: Direction? = nil, severity: Severity? = nil,
                fromDate: Date? = nil, toDate: Date? = nil, keyword: String? = nil)
    {
        self.direction = direction
        self.severity = severity
        self.fromDate = fromDate
        self.toDate = toDate
        self.keyword = keyword
    }
}
