import Testing
import Foundation
@testable import SieveGUICore

@Suite("sieve.purge_history 解码 + 参数编码（SPEC-005 §11B）")
struct PurgeHistoryTests {

    // MARK: - PurgeHistoryResult 解码

    @Test("标准响应解码：purged_at + rows_deleted")
    func decode_standard_result() throws {
        let json = """
        {
          "purged_at": "2026-05-03T08:00:00.123Z",
          "rows_deleted": 4721
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(PurgeHistoryResult.self, from: json)
        #expect(result.rowsDeleted == 4721)
        // purged_at 应能解码为合法 Date
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: result.purgedAt)
        #expect(comps.year == 2026)
        #expect(comps.month == 5)
        #expect(comps.day == 3)
    }

    @Test("rows_deleted 为 0（历史为空也算成功）")
    func decode_zero_rows() throws {
        let json = """
        {
          "purged_at": "2026-05-03T10:00:00.000Z",
          "rows_deleted": 0
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(PurgeHistoryResult.self, from: json)
        #expect(result.rowsDeleted == 0)
    }

    @Test("rows_deleted 大数值（UInt64 边界）")
    func decode_large_rows_deleted() throws {
        let json = """
        {
          "purged_at": "2026-05-03T10:00:00.000Z",
          "rows_deleted": 9999999
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(PurgeHistoryResult.self, from: json)
        #expect(result.rowsDeleted == 9_999_999)
    }

    // MARK: - PurgeHistoryParams 编码

    @Test("PurgeHistoryParams 编码为 confirmed_at ISO8601 snake_case")
    func encode_params_snake_case() throws {
        // 固定时间戳
        let date = Date(timeIntervalSince1970: 1_746_259_200)  // 2026-05-03T08:00:00Z
        let params = PurgeHistoryParams(confirmedAt: date)
        let data = try JSONEncoder().encode(params)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(dict?["confirmed_at"] is String)
        // camelCase key 不应出现
        #expect(dict?["confirmedAt"] == nil)
    }

    @Test("PurgeHistoryParams confirmed_at 包含有效 ISO8601 格式")
    func encode_params_iso8601_format() throws {
        let now = Date()
        let params = PurgeHistoryParams(confirmedAt: now)
        let data = try JSONEncoder().encode(params)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let confirmedAtStr = dict?["confirmed_at"] as? String else {
            Issue.record("confirmed_at should be a String")
            return
        }
        // 应能被 ISO8601DateFormatter 解析
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(f.date(from: confirmedAtStr) != nil)
    }

    // MARK: - 发送前状态门禁

    @Test("Touch ID 取消或失败时静默取消，不发送 purge_history")
    func send_decision_touchid_failure_cancels_silently() {
        let decision = PurgeHistorySendDecision.resolve(
            touchIDPassed: false,
            daemonStatus: .normal,
            purgeUnavailable: false,
            purging: false
        )

        #expect(decision == .cancelSilently)
    }

    @Test("Touch ID 通过后 daemon 若已断线，仍不得发送 purge_history")
    func send_decision_blocks_when_disconnected_after_touchid() {
        let decision = PurgeHistorySendDecision.resolve(
            touchIDPassed: true,
            daemonStatus: .disconnected(reason: .connectionRefused),
            purgeUnavailable: false,
            purging: false
        )

        #expect(decision == .blocked("清空失败，请检查 daemon 连接状态"))
    }

    @Test("旧 daemon 标记后不得发送 purge_history")
    func send_decision_blocks_when_purge_unavailable() {
        let decision = PurgeHistorySendDecision.resolve(
            touchIDPassed: true,
            daemonStatus: .normal,
            purgeUnavailable: true,
            purging: false
        )

        #expect(decision == .blocked("daemon 版本过旧，不支持清空历史（需升级 daemon）"))
    }

    @Test("已在清空中时不得重复发送 purge_history")
    func send_decision_blocks_duplicate_purge() {
        let decision = PurgeHistorySendDecision.resolve(
            touchIDPassed: true,
            daemonStatus: .normal,
            purgeUnavailable: false,
            purging: true
        )

        #expect(decision == .blocked("清空操作正在进行中，请稍候"))
    }

    @Test("Touch ID 通过且 daemon 已连接时允许发送 purge_history")
    func send_decision_allows_connected_daemon() {
        let decision = PurgeHistorySendDecision.resolve(
            touchIDPassed: true,
            daemonStatus: .paused(until: nil),
            purgeUnavailable: false,
            purging: false
        )

        #expect(decision == .send)
    }
}
