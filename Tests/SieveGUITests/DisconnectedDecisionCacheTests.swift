import Foundation
import Testing
@testable import SieveGUICore

/// SPEC-002 §6：HIPS 失联期间用户决策的本地缓存（入队 / 去重 / 重发-清空）。
/// 纯逻辑核心库类型；重连后由 HipsPanelManager 遍历重发，daemon 端按 request_id 去重。
@Suite("DisconnectedDecisionCache — 失联决策缓存")
struct DisconnectedDecisionCacheTests {
    private func makeSingle(id: String, decision: Decision) -> PendingDecisionPayload {
        let r = DecisionResponse(
            id: id, decision: decision, remember: false, contextHint: nil,
            byUser: true, uiPhaseWhenClicked: .blue
        )
        return .single(r, allowRemember: false)
    }

    @Test("新建缓存为空")
    func empty_on_init() {
        let cache = DisconnectedDecisionCache()
        #expect(cache.isEmpty)
        #expect(cache.count == 0)
    }

    @Test("store 后 drain 返回该决策并清空")
    func store_then_drain_returns_and_clears() {
        var cache = DisconnectedDecisionCache()
        cache.store(makeSingle(id: "req-1", decision: .deny))
        #expect(cache.count == 1)

        let drained = cache.drain()
        #expect(drained.count == 1)
        #expect(drained.first?.requestId == "req-1")
        #expect(cache.isEmpty) // drain 后清空
        #expect(cache.drain().isEmpty) // 二次 drain 为空（防重复重发）
    }

    @Test("同 request_id 去重，后者覆盖，仅重发一次")
    func dedupe_by_request_id_latest_wins() {
        var cache = DisconnectedDecisionCache()
        cache.store(makeSingle(id: "req-1", decision: .deny))
        cache.store(makeSingle(id: "req-1", decision: .allow)) // 同 id 覆盖
        #expect(cache.count == 1)

        let drained = cache.drain()
        #expect(drained.count == 1)
        if case let .single(r, _) = drained[0] {
            #expect(r.decision == .allow) // 后者胜出
        } else {
            Issue.record("expected .single payload")
        }
    }

    @Test("不同 request_id 按入队顺序重发")
    func preserves_insertion_order() {
        var cache = DisconnectedDecisionCache()
        cache.store(makeSingle(id: "a", decision: .deny))
        cache.store(makeSingle(id: "b", decision: .allow))
        cache.store(makeSingle(id: "c", decision: .deny))

        let ids = cache.drain().map(\.requestId)
        #expect(ids == ["a", "b", "c"])
    }

    @Test("merged 决策也可缓存并保留 request_id")
    func merged_payload_cached() {
        var cache = DisconnectedDecisionCache()
        let merged = MergedDecisionResponse(
            id: "m-1",
            perIssue: [.init(issueId: "i1", decision: .allow, remember: false, contextHint: nil, allowRemember: false)],
            byUser: true
        )
        cache.store(.merged(merged))

        let drained = cache.drain()
        #expect(drained.first?.requestId == "m-1")
        #expect(drained.first?.resultJSON()["request_id"] as? String == "m-1")
    }
}
