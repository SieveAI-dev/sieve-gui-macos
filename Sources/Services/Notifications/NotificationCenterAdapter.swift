import Foundation
import UserNotifications
import os.log

/// macOS 系统通知。失联/重连/auto-deny/前台外即将弹出。
@MainActor
public final class NotificationCenterAdapter {
    public static let shared = NotificationCenterAdapter()
    private let logger = Logger(subsystem: "com.sieve.gui", category: "notifications")

    public func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            return granted
        } catch {
            logger.error("notif auth failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    public func notifyDisconnected(reason: DaemonStatus.DisconnectReason) {
        post(title: "Sieve 与 daemon 失联",
             body: shortReason(reason),
             id: "disconnect-\(reason.rawValue)")
    }

    public func notifyReconnected() {
        post(title: "Sieve 已重新连接",
             body: "已与 daemon 完成握手。",
             id: "reconnect")
    }

    public func notifyAutoDeny(ruleTitle: String) {
        post(title: "Sieve 拦截：\(ruleTitle)",
             body: "GUI 渲染失败已自动拒绝。详情见调试窗口。",
             id: "auto-deny-\(UUID().uuidString)")
    }

    public func notifyHipsPending(ruleTitle: String) {
        post(title: "Sieve 需要你的确认",
             body: "请打开 Sieve GUI 处理：\(ruleTitle)",
             id: "hips-\(UUID().uuidString)")
    }

    private func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { Logger(subsystem: "com.sieve.gui", category: "notifications")
                .error("post fail: \(String(describing: err), privacy: .public)") }
        }
    }

    private func shortReason(_ r: DaemonStatus.DisconnectReason) -> String {
        switch r {
        case .socketMissing: return "找不到 daemon socket。"
        case .connectionRefused: return "daemon socket 拒绝连接，请重启 daemon。"
        case .heartbeatTimeout: return "30 秒未收到 daemon 消息。"
        case .versionMismatch: return "协议版本不兼容，请同步升级。"
        case .daemonShutdown: return "daemon 主动关闭。"
        case .unknown: return "未知原因。"
        }
    }
}
