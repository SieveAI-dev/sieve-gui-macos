import Foundation
import Testing
@testable import SieveGUICore

/// SPEC-002 §4.4 隔离决策：HIPS 字段解锁与 History 会话完全隔离、仅当前弹窗有效。
@Suite("HipsFieldUnlock：单弹窗解锁，跨弹窗自动失效")
struct HipsFieldUnlockTests {
    @Test("解锁绑定 request_id：本弹窗 true，其他弹窗 false")
    func unlock_is_scoped_to_request() {
        var unlock = HipsFieldUnlock()
        #expect(!unlock.isUnlocked(for: "req-1"))

        unlock.unlock(requestId: "req-1")
        #expect(unlock.isUnlocked(for: "req-1"))
        #expect(!unlock.isUnlocked(for: "req-2"))
    }

    @Test("换弹窗（新 request_id）→ 即使状态存活也不泄漏解锁")
    func stale_state_does_not_leak_across_popups() {
        var unlock = HipsFieldUnlock()
        unlock.unlock(requestId: "req-1")
        // 模拟 NSHostingController rootView 复用导致 @State 存活：不 reset，直接换请求
        #expect(!unlock.isUnlocked(for: "req-next"))
    }

    @Test("reset → 回到脱敏")
    func reset_clears_unlock() {
        var unlock = HipsFieldUnlock()
        unlock.unlock(requestId: "req-1")
        unlock.reset()
        #expect(!unlock.isUnlocked(for: "req-1"))
    }

    @Test("与 History 会话隔离：AppState.unlockSession 有效不影响 HIPS 解锁态")
    @MainActor
    func independent_from_history_session() throws {
        let defaults = try #require(UserDefaults(suiteName: "hips-unlock-tests-\(UUID().uuidString)"))
        let state = AppState(store: UserSettingsStore(defaults: defaults))
        state.setUnlockSession(UnlockSession(validFor: 300))
        #expect(state.isUnlocked == true)

        // History 解锁不放行 HIPS：HIPS 侧独立状态仍为脱敏
        let unlock = HipsFieldUnlock()
        #expect(!unlock.isUnlocked(for: "req-1"))

        // 反向：HIPS 解锁不写 AppState 会话（unlock 是值类型局部状态，无会话副作用）
        var hips = HipsFieldUnlock()
        hips.unlock(requestId: "req-1")
        state.setUnlockSession(nil)
        #expect(state.isUnlocked == false)
        #expect(hips.isUnlocked(for: "req-1"))
    }
}
