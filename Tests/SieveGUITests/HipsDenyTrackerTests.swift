import Testing
import Foundation
@testable import SieveGUICore

@Suite("HipsDenyTracker — 5s 内同 rule_id deny 后按钮互换逻辑")
struct HipsDenyTrackerTests {

    @Test("5s 内再次弹同 rule → shouldSwapLayout = true")
    func swap_within_window() {
        var tracker = HipsDenyTracker()
        let denyTime = Date()
        tracker.recordDeny(ruleId: "OUT-07", at: denyTime)

        // 4 秒后仍在窗口内
        let within = denyTime.addingTimeInterval(4)
        #expect(tracker.shouldSwapLayout(ruleId: "OUT-07", now: within) == true)
    }

    @Test("5s 后弹同 rule → shouldSwapLayout = false")
    func no_swap_after_window() {
        var tracker = HipsDenyTracker()
        let denyTime = Date()
        tracker.recordDeny(ruleId: "OUT-07", at: denyTime)

        // 6 秒后已超出窗口
        let after = denyTime.addingTimeInterval(6)
        #expect(tracker.shouldSwapLayout(ruleId: "OUT-07", now: after) == false)
    }

    @Test("从未 deny 过 → shouldSwapLayout = false")
    func no_swap_without_prior_deny() {
        let tracker = HipsDenyTracker()
        #expect(tracker.shouldSwapLayout(ruleId: "IN-CR-01") == false)
    }

    @Test("不同 rule_id 互不影响")
    func different_rule_ids_are_independent() {
        var tracker = HipsDenyTracker()
        let denyTime = Date()
        tracker.recordDeny(ruleId: "OUT-07", at: denyTime)

        let within = denyTime.addingTimeInterval(1)
        // OUT-07 应该 swap
        #expect(tracker.shouldSwapLayout(ruleId: "OUT-07", now: within) == true)
        // IN-CR-01 未 deny，不应 swap
        #expect(tracker.shouldSwapLayout(ruleId: "IN-CR-01", now: within) == false)
    }

    @Test("窗口边界：恰好 5s 不互换")
    func exact_boundary_no_swap() {
        var tracker = HipsDenyTracker()
        let denyTime = Date()
        tracker.recordDeny(ruleId: "OUT-09", at: denyTime)

        let exactly5 = denyTime.addingTimeInterval(HipsDenyTracker.swapWindowSeconds)
        #expect(tracker.shouldSwapLayout(ruleId: "OUT-09", now: exactly5) == false)
    }
}
