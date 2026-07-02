import Foundation
import Testing
@testable import SieveGUICore

/// InflightQueue 超时清扫（SPEC-008 §6 / OQ-008-02）。
/// daemon 收到请求但静默不响应且不断连时，sendRequest 的 await 会永久挂起；
/// sweepTimeouts 周期把超过 deadline 的 waiter 以 .timeout reject。
@Suite("InflightQueue timeout sweep")
struct InflightTimeoutTests {
    /// 超过 deadline 的 waiter 收到 .timeout 错误并被移除。
    @Test func expired_waiter_receives_timeout() async throws {
        let q = InflightQueue()
        let created = Date()
        await q.enqueue(.init(id: "slow", method: "m", payload: Data(), createdAt: created, isDecisionResponse: false))

        async let result: Data = withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            Task { await q.registerWaiter(id: "slow", continuation: cont) }
        }
        try await Task.sleep(nanoseconds: 5_000_000)

        // 注入「60s 之后」的时刻 + 短策略，让 entry 越过 deadline
        let policy = InflightQueue.TimeoutPolicy(defaultSeconds: 60, evaluateSeconds: 90)
        let expired = await q.sweepTimeouts(now: created.addingTimeInterval(61), policy: policy)
        #expect(expired == ["slow"])
        #expect(await q.count() == 0)
        #expect(await q.waiterCount() == 0)

        do {
            _ = try await result
            Issue.record("expected timeout throw")
        } catch InflightQueue.AwaitError.timeout {
            // 正确
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// 未超时的 entry 不受清扫影响。
    @Test func fresh_waiter_unaffected() async throws {
        let q = InflightQueue()
        let created = Date()
        await q.enqueue(.init(id: "fresh", method: "m", payload: Data(), createdAt: created, isDecisionResponse: false))

        async let result: Data = withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            Task { await q.registerWaiter(id: "fresh", continuation: cont) }
        }
        try await Task.sleep(nanoseconds: 5_000_000)

        // 仅过了 10s，未达 60s deadline
        let expired = await q.sweepTimeouts(now: created.addingTimeInterval(10))
        #expect(expired.isEmpty)
        #expect(await q.count() == 1)
        #expect(await q.waiterCount() == 1)

        // 仍能正常 fulfill
        let payload = Data("{\"ok\":true}".utf8)
        await q.fulfill(id: "fresh", resultData: payload)
        let got = try await result
        #expect(got == payload)
    }

    /// 混合：仅超时的被清，新鲜的保留。
    @Test func mixed_only_expired_swept() async {
        let q = InflightQueue()
        let base = Date()
        await q.enqueue(.init(id: "old", method: "m", payload: Data(), createdAt: base, isDecisionResponse: false))
        await q.enqueue(.init(
            id: "new",
            method: "m",
            payload: Data(),
            createdAt: base.addingTimeInterval(55),
            isDecisionResponse: false
        ))

        let expired = await q.sweepTimeouts(now: base.addingTimeInterval(61))
        #expect(expired == ["old"])
        #expect(await q.count() == 1)
        #expect(await q.allPending().first?.id == "new")
    }

    /// evaluate 类方法走 90s deadline：60s 时未超时，91s 时超时。
    @Test func evaluate_method_uses_longer_deadline() async {
        let q = InflightQueue()
        let base = Date()
        await q.enqueue(.init(
            id: "ev",
            method: "sieve.evaluate",
            payload: Data(),
            createdAt: base,
            isDecisionResponse: false
        ))

        // 70s：超过默认 60s 但未到 evaluate 90s
        let none = await q.sweepTimeouts(now: base.addingTimeInterval(70))
        #expect(none.isEmpty)
        #expect(await q.count() == 1)

        // 91s：越过 evaluate deadline
        let expired = await q.sweepTimeouts(now: base.addingTimeInterval(91))
        #expect(expired == ["ev"])
        #expect(await q.count() == 0)
    }

    /// 无 waiter 的 fire-and-forget entry 超时也会被清掉（防 entries 泄漏）。
    @Test func orphan_entry_swept_without_waiter() async {
        let q = InflightQueue()
        let base = Date()
        await q.enqueue(.init(id: "orphan", method: "m", payload: Data(), createdAt: base, isDecisionResponse: false))

        let expired = await q.sweepTimeouts(now: base.addingTimeInterval(61))
        #expect(expired == ["orphan"])
        #expect(await q.count() == 0)
    }

    /// TimeoutPolicy.deadline：method 名含 "evaluate" 走 evaluate 阈值，否则默认。
    @Test func policy_routes_by_method_name() {
        let policy = InflightQueue.TimeoutPolicy(defaultSeconds: 60, evaluateSeconds: 90)
        #expect(policy.deadline(forMethod: "sieve.evaluate") == 90)
        #expect(policy.deadline(forMethod: "evaluate_batch") == 90)
        #expect(policy.deadline(forMethod: "sieve.set_preset") == 60)
        #expect(policy.deadline(forMethod: "decision_response") == 60)
    }
}
