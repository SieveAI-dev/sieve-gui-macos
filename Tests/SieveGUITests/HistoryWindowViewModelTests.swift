import Foundation
import SQLite3
import Testing
@testable import SieveGUICore

@Suite("HistoryWindowViewModel — pagination state")
struct HistoryWindowViewModelTests {
    @Test("超过 200 行内存窗口后继续翻页不重复 offset=200 页")
    @MainActor
    func load_more_uses_stable_page_offset_after_window_trim() async throws {
        let path = try makeAuditDB(rowCount: 260)
        let reader = AuditDBReader()
        let viewModel = HistoryWindowViewModel(reader: reader)
        viewModel.start(openPath: path)
        defer { reader.close() }

        try await waitUntil { viewModel.rows.count == 50 && !viewModel.loading }

        for _ in 0 ..< 5 {
            let previousLastId = viewModel.rows.last?.id
            viewModel.loadMore()
            try await waitUntil {
                !viewModel.loading && (viewModel.rows.last?.id != previousLastId || viewModel.reachedEnd)
            }
        }

        let ids = viewModel.rows.map(\.id)
        #expect(ids.count == 200)
        #expect(Set(ids).count == 200, "翻页超过 maxKept 后不应重复加载同一页")
        #expect(ids.first == 200)
        #expect(ids.last == 1, "应能继续翻到最旧记录，而不是停在 offset=200 的重复页")
        #expect(viewModel.reachedEnd)

        try? FileManager.default.removeItem(atPath: path)
    }

    @Test("从最近命中跳到窗口外记录后，后续翻页不重复该记录")
    @MainActor
    func revealed_out_of_window_event_is_not_duplicated_by_later_pages() async throws {
        let path = try makeAuditDB(rowCount: 260)
        let reader = AuditDBReader()
        let viewModel = HistoryWindowViewModel(reader: reader)
        viewModel.start(openPath: path)
        defer { reader.close() }

        try await waitUntil { viewModel.rows.count == 50 && !viewModel.loading }
        viewModel.selectAndReveal(requestId: "req_120")
        try await waitUntil { viewModel.selected?.id == 120 }

        for _ in 0 ..< 3 {
            let previousLastId = viewModel.rows.last?.id
            viewModel.loadMore()
            try await waitUntil {
                !viewModel.loading && (viewModel.rows.last?.id != previousLastId || viewModel.reachedEnd)
            }
        }

        let ids = viewModel.rows.map(\.id)
        #expect(ids.contains(120))
        #expect(ids.filter { $0 == 120 }.count == 1, "置顶揭示的记录翻到原位置时不应重复出现")
        #expect(Set(ids).count == ids.count)

        try? FileManager.default.removeItem(atPath: path)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("condition timed out")
    }

    private func makeAuditDB(rowCount: Int) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sieve_history_vm_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("audit.db").path

        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw HistoryVMFixtureError.openFailed }
        defer { sqlite3_close(db) }

        try exec(db, "PRAGMA user_version = 2")
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

        for id in 1 ... rowCount {
            try exec(db, """
            INSERT INTO events
            (id, created_at, direction, severity, rule_id, disposition, user_choice,
             fingerprint, session_id, caller_pid, caller_exe, evidence_meta, request_id)
            VALUES
            (\(id), '2026-01-01T00:00:00Z', 'outbound', 'low', 'OUT-07',
             'auto_redact', NULL, 'fp_\(id)', 'sess_\(id)', 1000, '/usr/bin/codex',
             '{"row":\(id)}', 'req_\(id)')
            """)
        }
        return path
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let msg = errmsg.map { ptr in String(cString: ptr) } ?? "unknown"
            sqlite3_free(errmsg)
            throw HistoryVMFixtureError.execFailed(msg)
        }
    }

    private enum HistoryVMFixtureError: Error {
        case openFailed
        case execFailed(String)
    }
}
