import Foundation
import Testing
@testable import SieveGUICore

/// P1-1：解锁会话到期必须主动清空（发 @Published），不能依赖读取时惰性重算——
/// 否则已打开的 History Inspector 无新渲染时明文 evidence 可超时仍显示。
@Suite("UnlockSession 过期主动清空")
struct UnlockSessionExpiryTests {
    @MainActor
    private func makeState() -> AppState {
        let defaults = UserDefaults(suiteName: "unlock-expiry-tests-\(UUID().uuidString)")!
        return AppState(store: UserSettingsStore(defaults: defaults))
    }

    @Test("短 TTL 会话到期 → unlockSession 被定时器主动置空（非读取触发）")
    @MainActor
    func session_expires_proactively() async throws {
        let state = makeState()
        state.setUnlockSession(UnlockSession(validFor: 0.05))
        #expect(state.unlockSession != nil)

        try await Task.sleep(nanoseconds: 400_000_000)
        // 断言存储属性本身已被清空——这只可能来自过期定时器，不是 isValid() 惰性判定
        #expect(state.unlockSession == nil)
        #expect(state.isUnlocked == false)
    }

    @Test("重设会话 → 旧定时器取消，新会话不被旧期限误清")
    @MainActor
    func resetting_session_cancels_previous_timer() async throws {
        let state = makeState()
        state.setUnlockSession(UnlockSession(validFor: 0.05))
        state.setUnlockSession(UnlockSession(validFor: 60))

        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(state.unlockSession != nil)
        #expect(state.isUnlocked == true)
    }

    @Test("清空会话（nil）→ 幂等且取消定时器")
    @MainActor
    func clearing_session_is_idempotent() {
        let state = makeState()
        state.setUnlockSession(UnlockSession(validFor: 60))
        state.setUnlockSession(nil)
        #expect(state.unlockSession == nil)
        state.setUnlockSession(nil)
        #expect(state.unlockSession == nil)
    }
}
