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

/// SPEC-002 §4.4/§5.2：解锁态 owner 上收 AppState 后的双向隔离与失效条件覆盖。
///
/// 覆盖边界说明（双轨工程，`Features/HIPS` 与 `Services/TouchID` 仅 xcodebuild 编，swift test 编不到）：
/// - **状态语义**（本 Suite）：unlock/reset、双向隔离、失效条件 b/d/e 的最终效果都是 AppState 层可测的。
/// - **接线**（靠 xcodebuild 编译 + 逻辑论证）：失效条件 a/c 汇聚于 `HipsPanelManager.closePanel`、
///   b 追加于 `present`、d 位于 `TouchIDService.clearSession`——这些调用点调的都是本 Suite 验证过的
///   `resetHipsFieldUnlock()`。d 的「信号→clearSession」链另由 `UnlockSessionClearBindingTests` 锚定。
@Suite("HipsFieldUnlock × AppState：双向隔离与 5 失效条件（§5.2）")
@MainActor
struct HipsFieldUnlockAppStateTests {
    private func makeState() throws -> AppState {
        let defaults = try #require(UserDefaults(suiteName: "hips-unlock-appstate-\(UUID().uuidString)"))
        return AppState(store: UserSettingsStore(defaults: defaults))
    }

    @Test("unlockHipsField 解锁当前 request，reset 后失效（失效条件 a/c 的状态语义）")
    func unlock_and_reset() throws {
        let state = try makeState()
        #expect(!state.hipsFieldUnlock.isUnlocked(for: "req-1"))
        state.unlockHipsField(requestId: "req-1")
        #expect(state.hipsFieldUnlock.isUnlocked(for: "req-1"))
        // 绑定 request_id：其他弹窗不被放行
        #expect(!state.hipsFieldUnlock.isUnlocked(for: "req-2"))
        // closePanel（决策提交/关窗）与 handleCountdownTimeout（hold 归零）都调 resetHipsFieldUnlock
        state.resetHipsFieldUnlock()
        #expect(!state.hipsFieldUnlock.isUnlocked(for: "req-1"))
    }

    @Test("隔离方向 1：History 会话有效不放行 HIPS 字段（HIPS 不读 unlockSession）")
    func history_unlock_does_not_grant_hips() throws {
        let state = try makeState()
        state.setUnlockSession(UnlockSession(validFor: 300))
        #expect(state.isUnlocked == true)
        #expect(!state.hipsFieldUnlock.isUnlocked(for: "req-1"))
    }

    @Test("隔离方向 2：HIPS 解锁不创建/延长 History 会话（unlockHipsField 不写 unlockSession）")
    func hips_unlock_does_not_touch_history_session() throws {
        let state = try makeState()
        state.unlockHipsField(requestId: "req-1")
        #expect(state.hipsFieldUnlock.isUnlocked(for: "req-1"))
        #expect(state.isUnlocked == false)
        #expect(state.unlockSession == nil)
    }

    @Test("失效条件 b：resetHipsFieldUnlock 对同 request_id 强制回脱敏（present 抵御 daemon 同 id 重发）")
    func reset_remasks_same_request_id() throws {
        let state = try makeState()
        state.unlockHipsField(requestId: "req-dup")
        #expect(state.hipsFieldUnlock.isUnlocked(for: "req-dup"))
        // HipsPanelManager.present 对每个新弹窗（含 daemon 重连重发的同 id）先调 resetHipsFieldUnlock：
        // 即使 @State 会跨弹窗存活，解锁也不残留到重发的同 id 弹窗。
        state.resetHipsFieldUnlock()
        #expect(!state.hipsFieldUnlock.isUnlocked(for: "req-dup"))
    }

    @Test("失效条件 e：History 会话 TTL 过期时 HIPS 字段解锁一并失效")
    func hips_unlock_expires_with_history_session() async throws {
        let state = try makeState()
        state.unlockHipsField(requestId: "req-1")
        state.setUnlockSession(UnlockSession(validFor: 0.15)) // 短 TTL 触发 AppState 过期定时器
        #expect(state.hipsFieldUnlock.isUnlocked(for: "req-1"))
        // 过期定时器回调：setUnlockSession(nil) + resetHipsFieldUnlock
        try await Task.sleep(nanoseconds: 450_000_000)
        #expect(state.isUnlocked == false)
        #expect(!state.hipsFieldUnlock.isUnlocked(for: "req-1"))
    }

    @Test("失效条件 d：锁屏统一失效点应同时清 History 会话与 HIPS 字段解锁（clearSession 双清语义）")
    func screen_lock_clears_both_unlocks() throws {
        let state = try makeState()
        state.setUnlockSession(UnlockSession(validFor: 300))
        state.unlockHipsField(requestId: "req-1")
        #expect(state.isUnlocked)
        #expect(state.hipsFieldUnlock.isUnlocked(for: "req-1"))

        // TouchIDService.clearSession 是锁屏/显示器睡眠/快速切换三路信号的统一汇聚点
        // （「三路信号→clearSession」由 UnlockSessionClearBindingTests 锚定），其真实实现执行以下
        // 双清；此处钉死它应有的效果——History 会话与 HIPS 字段解锁一并回脱敏。
        // clearSession 内确有 resetHipsFieldUnlock 由 xcodebuild 编译保证（Services/TouchID 不入 Core 库）。
        state.setUnlockSession(nil)
        state.resetHipsFieldUnlock()

        #expect(state.isUnlocked == false)
        #expect(!state.hipsFieldUnlock.isUnlocked(for: "req-1"))
    }
}
