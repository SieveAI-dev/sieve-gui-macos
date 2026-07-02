import Foundation
import Testing
@testable import SieveGUICore

/// P0-4：失联期间关窗不再静默丢弃取消帧，按 deny 入失联缓存待重连重发。
@Suite("DisconnectedCloseFallback：失联关窗按拒绝缓存")
struct DisconnectedCloseFallbackTests {
    private func makeRequest(merged: Bool, allowRemember: Bool = true) -> HipsRequest {
        HipsRequest(
            id: "req-close",
            requestId: "req-close",
            title: "Test",
            severity: .critical,
            direction: .inbound,
            timeoutSeconds: 30,
            defaultOnTimeout: .block,
            allowRemember: allowRemember,
            merged: merged,
            receivedAtDaemon: nil,
            ruleId: merged ? nil : "IN-CR-01",
            context: merged ? nil : .generic(.init(payload: AnyCodable(rawData: Data()))),
            recommendation: nil,
            issues: merged ? [
                HipsIssue(
                    id: "i1", ruleId: "IN-CR-01", title: "t1", severity: .critical,
                    allowRemember: false,
                    context: .generic(.init(payload: AnyCodable(rawData: Data()))),
                    recommendation: nil
                ),
                HipsIssue(
                    id: "i2", ruleId: "IN-CR-02", title: "t2", severity: .high,
                    allowRemember: true,
                    context: .generic(.init(payload: AnyCodable(rawData: Data()))),
                    recommendation: nil
                )
            ] : [],
            rawJSON: nil
        )
    }

    @Test("单 issue：payload 为 deny、by_user=true、remember=false")
    func single_close_becomes_deny() {
        let payload = DisconnectedCloseFallback.payload(for: makeRequest(merged: false), phase: .orange)
        guard case let .single(response, allowRemember) = payload else {
            Issue.record("payload 应为 .single")
            return
        }
        #expect(response.decision == .deny)
        #expect(response.byUser == true)
        #expect(response.remember == false)
        #expect(allowRemember == true)
        #expect(payload.requestId == "req-close")
    }

    @Test("merged：payload 为 denyAll 语义（全部 per-issue deny）")
    func merged_close_becomes_deny_all() {
        let payload = DisconnectedCloseFallback.payload(for: makeRequest(merged: true), phase: .red)
        guard case let .merged(response) = payload else {
            Issue.record("payload 应为 .merged")
            return
        }
        #expect(response.perIssue.count == 2)
        #expect(response.perIssue.allSatisfy { $0.decision == .deny })
        #expect(response.byUser == true)
        #expect(response.mergedDecisionLabel == "all_deny")
    }

    @Test("入缓存 → drain 取回同一条（重连重发链路衔接）")
    func payload_round_trips_through_cache() {
        var cache = DisconnectedDecisionCache()
        cache.store(DisconnectedCloseFallback.payload(for: makeRequest(merged: false), phase: .blue))
        let drained = cache.drain()
        #expect(drained.count == 1)
        #expect(drained.first?.requestId == "req-close")
        guard case let .single(response, _)? = drained.first else {
            Issue.record("drain 结果应为 .single")
            return
        }
        #expect(response.decision == .deny)
    }
}
