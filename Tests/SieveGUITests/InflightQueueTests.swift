import Foundation
import Testing
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
        await q.enqueue(.init(
            id: "1",
            method: "regular",
            payload: Data(),
            createdAt: Date(),
            isDecisionResponse: false
        ))
        await q.enqueue(.init(
            id: "2",
            method: "decision_response",
            payload: Data(),
            createdAt: Date(),
            isDecisionResponse: true
        ))
        let pending = await q.allPending()
        #expect(pending.first?.id == "2")
    }
}

@Suite("InflightQueue clearAndDiscard")
struct InflightQueueClearTests {
    @Test func reconnect_clears_entries_and_wakes_waiter_with_error() async {
        let q = InflightQueue()
        await q.enqueue(.init(
            id: "req-1",
            method: "sieve.set_preset",
            payload: Data(),
            createdAt: Date(),
            isDecisionResponse: false
        ))

        // 注册 waiter
        async let result: Data = withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            Task { await q.registerWaiter(id: "req-1", continuation: cont) }
        }
        try? await Task.sleep(nanoseconds: 1_000_000)

        // 模拟重连触发丢弃
        await q.clearAndDiscard()
        #expect(await q.count() == 0)
        #expect(await q.waiterCount() == 0)

        // waiter 应收到 .reconnectedDiscarded 错误
        do {
            _ = try await result
            Issue.record("expected throw")
        } catch InflightQueue.AwaitError.reconnectedDiscarded {
            // 正确
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func clearAndDiscard_removes_all_entries() async {
        let q = InflightQueue()
        await q.enqueue(.init(id: "1", method: "m", payload: Data(), createdAt: Date(), isDecisionResponse: false))
        await q.enqueue(.init(id: "2", method: "m", payload: Data(), createdAt: Date(), isDecisionResponse: true))
        await q.clearAndDiscard()
        #expect(await q.count() == 0)
    }
}

@Suite("UserSettings persistence")
struct UserSettingsTests {
    @Test func clamps_toast_duration() throws {
        let d = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        let store = UserSettingsStore(defaults: d)
        var s = UserSettings.default
        s.toastDurationSeconds = 100
        store.save(s)
        let loaded = store.load()
        #expect(loaded.toastDurationSeconds == 10)
    }

    @Test func lastSeenDaemonBootId_roundtrip() throws {
        let d = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        let store = UserSettingsStore(defaults: d)
        #expect(store.lastSeenDaemonBootId() == nil)
        store.setLastSeenDaemonBootId("boot-abc")
        #expect(store.lastSeenDaemonBootId() == "boot-abc")
    }

    @Test func autoCheckUpdates_roundtrip() throws {
        let d = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        let store = UserSettingsStore(defaults: d)
        var s = UserSettings.default
        s.autoCheckUpdates = false
        store.save(s)

        #expect(store.load().autoCheckUpdates == false)

        s.autoCheckUpdates = true
        store.save(s)
        #expect(store.load().autoCheckUpdates == true)
    }

    @Test func hips_sound_preferences_roundtrip() throws {
        let d = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        let store = UserSettingsStore(defaults: d)
        var s = UserSettings.default
        s.hipsSoundEnabled = false
        s.hipsSoundName = "Ping"

        store.save(s)
        let loaded = store.load()

        #expect(loaded.hipsSoundEnabled == false)
        #expect(loaded.hipsSoundName == "Ping")
    }
}

@MainActor
private final class MockAppUpdater: AppUpdater {
    var isAutoCheckEnabled: Bool = false
    private(set) var checkCount: Int = 0

    func checkForUpdates() {
        checkCount += 1
    }
}

@Suite("Updates Settings")
@MainActor
struct UpdatesSettingsTests {
    @Test func syncs_auto_check_setting_to_updater() {
        let updater = MockAppUpdater()

        UpdateSettingsSync.applyAutoCheckSetting(true, to: updater)
        #expect(updater.isAutoCheckEnabled == true)

        UpdateSettingsSync.applyAutoCheckSetting(false, to: updater)
        #expect(updater.isAutoCheckEnabled == false)
    }
}

/// daemon_boot_id 三路判定的纯 store 层测试（AppStateIPCAdapter 在 App/ 层，SPM 测试用 store 验证）
@Suite("daemon_boot_id 三路重连逻辑")
struct DaemonBootIdTests {
    /// 模拟 AppStateIPCAdapter.checkAndUpdateDaemonBootId 的判定逻辑
    private func checkAndUpdate(store: UserSettingsStore, newBootId: String) -> ReconnectKind? {
        let last = store.lastSeenDaemonBootId()
        store.setLastSeenDaemonBootId(newBootId)
        guard let last else { return nil }
        return last != newBootId ? .daemonRestarted : .reconnected
    }

    @Test func first_connection_returns_nil() throws {
        let d = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        let store = UserSettingsStore(defaults: d)
        let kind = checkAndUpdate(store: store, newBootId: "boot-new")
        #expect(kind == nil) // 首次连接：无 toast
    }

    @Test func same_boot_id_returns_reconnected() throws {
        let d = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        let store = UserSettingsStore(defaults: d)
        store.setLastSeenDaemonBootId("boot-123")
        let kind = checkAndUpdate(store: store, newBootId: "boot-123")
        #expect(kind == .reconnected) // 连接中断重连
    }

    @Test func different_boot_id_returns_daemon_restarted() throws {
        let d = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        let store = UserSettingsStore(defaults: d)
        store.setLastSeenDaemonBootId("boot-old")
        let kind = checkAndUpdate(store: store, newBootId: "boot-new")
        #expect(kind == .daemonRestarted) // daemon 重启
    }

    @Test func boot_id_persisted_after_check() throws {
        let d = try #require(UserDefaults(suiteName: "test-\(UUID().uuidString)"))
        let store = UserSettingsStore(defaults: d)
        _ = checkAndUpdate(store: store, newBootId: "boot-xyz")
        #expect(store.lastSeenDaemonBootId() == "boot-xyz")
    }
}
