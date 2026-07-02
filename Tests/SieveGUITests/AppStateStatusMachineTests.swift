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
        try state.applyHello(makeHello())
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

    @Test("socket 存在但拒绝连接时显示 connectionRefused，而不是误报 socketMissing")
    func connectionRefusedIsDistinctFromMissingSocket() {
        let state = makeState()
        state.applyDisconnect(reason: .connectionRefused)
        #expect(state.daemonStatus == .disconnected(reason: .connectionRefused))
    }

    @Test("Toast 栈满时 terminal/generic 降级可显式累计角标")
    func toastOverflowBumpsWarningBadge() {
        let state = makeState()
        state.markConnected()
        state.recordToastOverflow()
        #expect(state.warningHitCount == 1)
        #expect(state.daemonStatus == .warning)
    }

    @Test("菜单栏图标状态描述符合 SPEC-001 的颜色与无障碍名称")
    func statusBarIconPresentationMatchesSpec() {
        let normal = StatusBarIconPresentation.resolve(for: .normal)
        #expect(normal.tint == .template)
        #expect(normal.accessibilityTitle == "Sieve — 正常")

        let warning = StatusBarIconPresentation.resolve(for: .warning)
        #expect(warning.tint == .warning)
        #expect(warning.symbolName.contains("exclamationmark"))
        #expect(warning.accessibilityTitle == "Sieve — 有警告")

        let hold = StatusBarIconPresentation.resolve(for: .hold)
        #expect(hold.tint == .danger)
        #expect(hold.accessibilityTitle == "Sieve — 等待用户决策")

        let paused = StatusBarIconPresentation.resolve(for: .paused(until: nil))
        #expect(paused.tint == .disabled)
        #expect(paused.accessibilityTitle == "Sieve — 已暂停")

        let disconnected = StatusBarIconPresentation.resolve(for: .disconnected(reason: .connectionRefused))
        #expect(disconnected.tint == .danger)
        #expect(disconnected.accessibilityTitle == "Sieve — 失联")
    }

    @Test("退出命令必须提示 daemon 仍在运行")
    func quitConfirmationWarnsDaemonKeepsRunning() {
        let content = QuitConfirmationContent.menuBarDefault
        #expect(content.message == "退出 Sieve GUI？")
        #expect(content.informativeText.contains("daemon 仍在运行"))
        #expect(content.informativeText.contains("重新打开 Sieve GUI 即可恢复 HIPS 弹窗"))
        #expect(content.confirmButtonTitle == "退出")
        #expect(content.cancelButtonTitle == "取消")
    }
}
