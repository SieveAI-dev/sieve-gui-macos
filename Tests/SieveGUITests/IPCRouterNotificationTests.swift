import Foundation
import Testing
@testable import SieveGUICore

/// P1-4：`sieve.reload_user_rules` 通知不再落 default 丢弃，路由为规则总览刷新广播。
@Suite("IPCRouter：reload_user_rules 通知路由")
struct IPCRouterNotificationTests {
    @Test("收到 sieve.reload_user_rules → 同步广播 .sieveUserRulesReloaded")
    @MainActor
    func reload_user_rules_posts_refresh_notification() {
        var received = false
        let observer = NotificationCenter.default.addObserver(
            forName: .sieveUserRulesReloaded, object: nil, queue: nil
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        IPCRouter.shared.handleDaemonNotification(
            method: "sieve.reload_user_rules",
            paramsData: Data("{}".utf8)
        )
        #expect(received)
    }

    @Test("未知通知仍走 default（不误伤）")
    @MainActor
    func unknown_notification_does_not_post() {
        var received = false
        let observer = NotificationCenter.default.addObserver(
            forName: .sieveUserRulesReloaded, object: nil, queue: nil
        ) { _ in received = true }
        defer { NotificationCenter.default.removeObserver(observer) }

        IPCRouter.shared.handleDaemonNotification(
            method: "sieve.some_future_notification",
            paramsData: Data("{}".utf8)
        )
        #expect(!received)
    }
}
