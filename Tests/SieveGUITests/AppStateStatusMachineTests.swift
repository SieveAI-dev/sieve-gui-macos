import Foundation
import Testing
@testable import SieveGUICore

/// 菜单栏状态机回归测试。
///
/// 守护 2026-06-23 盘点发现的死锁：`rescheduleStatus()` 曾用 `daemonStatus` 自身
/// 做失联守卫（`if case .disconnected { return }`），而初始态即 disconnected，导致
/// `markConnected()` / `applyHello()` 握手成功后永远无法离开失联态——图标握手后永久
/// 红点。修复：用独立 `ipcConnected` 事实位替代自指守卫。
@MainActor
@Suite("AppState 菜单栏状态机（回归 MenuBar 握手死锁）")
struct AppStateStatusMachineTests {
    private func makeState() -> AppState {
        // 隔离 UserDefaults，避免污染真实域。
        let defaults = UserDefaults(suiteName: "test-appstate-\(UUID().uuidString)")!
        return AppState(store: UserSettingsStore(defaults: defaults))
    }

    private func makeHello(paused: Bool = false) throws -> HelloParams {
        let json = """
        {"protocol_version":"v2","daemon_version":"1.0.0","daemon_boot_id":"boot-1",\
        "paused":\(paused),"preset":"standard","uptime_seconds":10,"audit_db_user_version":2}
        """
        return try JSONDecoder().decode(HelloParams.self, from: Data(json.utf8))
    }

    @Test("初始态为 socket 缺失的 disconnected")
    func initialStateIsDisconnected() {
        let state = makeState()
        #expect(state.daemonStatus == .disconnected(reason: .socketMissing))
    }

    @Test("握手成功（IPCClient .active → markConnected）后必须离开失联态")
    func markConnectedLeavesDisconnected() {
        let state = makeState()
        state.markConnected()
        #expect(state.daemonStatus == .normal)
    }

    @Test("applyHello 握手投递后必须离开失联态")
    func applyHelloLeavesDisconnected() throws {
        let state = makeState()
        state.applyHello(try makeHello())
        #expect(state.daemonStatus == .normal)
    }

    @Test("已连接后断连仍能回到 disconnected（保留失联检测）")
    func disconnectAfterConnected() {
        let state = makeState()
        state.markConnected()
        #expect(state.daemonStatus == .normal)
        state.applyDisconnect(reason: .heartbeatTimeout)
        #expect(state.daemonStatus == .disconnected(reason: .heartbeatTimeout))
    }

    @Test("协议版本不匹配优先级最高（连接态也压成 disconnected）")
    func versionMismatchTakesPriority() {
        let state = makeState()
        state.markConnected()
        state.setIPCVersionMismatch(true)
        #expect(state.daemonStatus == .disconnected(reason: .versionMismatch))
    }

    @Test("断连后重连可再次离开失联态（重连恢复）")
    func reconnectRecovers() {
        let state = makeState()
        state.markConnected()
        state.applyDisconnect(reason: .heartbeatTimeout)
        #expect(state.daemonStatus == .disconnected(reason: .heartbeatTimeout))
        state.markConnected()
        #expect(state.daemonStatus == .normal)
    }
}
