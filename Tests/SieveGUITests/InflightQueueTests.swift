import Testing
import Foundation
@testable import SieveGUICore

@Suite("InflightQueue")
struct InflightQueueTests {
    @Test func enqueue_then_fulfill() async {
        let q = InflightQueue()
        await q.enqueue(.init(id: "1", method: "m", payload: Data(), createdAt: Date(), isDecisionResponse: false))
        #expect(await q.count() == 1)
        await q.fulfill(id: "1", resultData: Data())
        #expect(await q.count() == 0)
    }

    @Test func waiter_resumes_on_fulfill() async throws {
        let q = InflightQueue()
        let payload = Data("{\"ok\":true}".utf8)
        async let result: Data = withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            Task { await q.registerWaiter(id: "w", continuation: cont) }
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        await q.fulfill(id: "w", resultData: payload)
        let got = try await result
        #expect(got == payload)
    }

    @Test func waiter_throws_on_reject() async {
        let q = InflightQueue()
        async let result: Data = withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            Task { await q.registerWaiter(id: "w2", continuation: cont) }
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        await q.reject(id: "w2", code: -32010, message: "critical_lock_violation", data: nil)
        do { _ = try await result; Issue.record("expected throw") }
        catch let InflightQueue.AwaitError.rpcError(code, msg, _) {
            #expect(code == -32010); #expect(msg == "critical_lock_violation")
        } catch { Issue.record("unexpected: \(error)") }
    }

    @Test func decision_responses_are_first() async {
        let q = InflightQueue()
        await q.enqueue(.init(id: "1", method: "regular", payload: Data(), createdAt: Date(), isDecisionResponse: false))
        await q.enqueue(.init(id: "2", method: "decision_response", payload: Data(), createdAt: Date(), isDecisionResponse: true))
        let pending = await q.allPending()
        #expect(pending.first?.id == "2")
    }
}

@Suite("UserSettings persistence")
struct UserSettingsTests {
    @Test func clamps_toast_duration() {
        let d = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let store = UserSettingsStore(defaults: d)
        var s = UserSettings.default
        s.toastDurationSeconds = 100
        store.save(s)
        let loaded = store.load()
        #expect(loaded.toastDurationSeconds == 10)
    }
}
