import Foundation
import Testing
@testable import SieveGUICore

/// P1-2：锁屏清会话监听的是真锁屏信号（com.apple.screenIsLocked）而非只有显示器睡眠。
/// TouchIDService 在 Features 层（swift test 编不到），此处锚定其消费的绑定逻辑与信号清单。
@Suite("UnlockSessionClearBinding：三路信号任一触发清会话")
struct UnlockSessionClearBindingTests {
    @Test("register 注册全部三路信号，任一触发 → clearSession 被调用")
    func all_signals_registered_and_each_clears() {
        final class Counter: @unchecked Sendable {
            var count = 0
        }
        var handlers: [String: () -> Void] = [:]
        let cleared = Counter()
        UnlockSessionClearBinding.register(
            subscribe: { name, handler in handlers[name] = handler },
            clearSession: { cleared.count += 1 }
        )

        #expect(Set(handlers.keys) == Set(UnlockSessionClearBinding.allSignalNames))
        #expect(handlers.count == 3)

        handlers["com.apple.screenIsLocked"]?()
        #expect(cleared.count == 1)
        handlers["NSWorkspaceScreensDidSleepNotification"]?()
        handlers["NSWorkspaceSessionDidResignActiveNotification"]?()
        #expect(cleared.count == 3)
    }

    @Test("信号清单锚定：真锁屏（screenIsLocked）必须在列（防回归到只挂 screensDidSleep）")
    func signal_list_pins_real_screen_lock() {
        #expect(UnlockSessionClearBinding.distributedSignalNames == ["com.apple.screenIsLocked"])
        #expect(UnlockSessionClearBinding.workspaceSignalNames == [
            "NSWorkspaceScreensDidSleepNotification",
            "NSWorkspaceSessionDidResignActiveNotification"
        ])
    }
}
