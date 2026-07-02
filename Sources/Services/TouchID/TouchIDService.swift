import AppKit
import Foundation
import LocalAuthentication
import os.log

/// Touch ID 解锁会话。一次解锁后 5 分钟内有效。
/// 红线：失败/取消只回退脱敏视图，不再次弹窗；锁屏唤醒后强制清除会话。
@MainActor
public final class TouchIDService: NSObject {
    public static let shared = TouchIDService()
    private let logger = Logger(subsystem: "com.sieve.gui", category: "touchid")

    private let appState = AppState.shared
    private var sessionClearObservers: [NSObjectProtocol] = []

    override public init() {
        super.init()
        observeScreenLock()
    }

    public func authenticate(reason: String) async -> Bool {
        let ok = await evaluate(reason: reason)
        if ok {
            appState.setUnlockSession(UnlockSession())
            await GUILog.shared.info("Touch ID 解锁成功，会话有效 5 分钟", category: "touchid")
        }
        return ok
    }

    /// P0-1：Critical 决策批准的「人在场」认证。与 History 解锁不同：成功**不建立**
    /// 解锁会话、不解锁任何脱敏字段，只作为一次性放行因子。
    /// deviceOwnerAuthentication 自带系统密码回退，无 Touch ID 的机器不会被锁死。
    public func authenticateForCriticalDecision(reason: String) async -> Bool {
        await evaluate(reason: reason)
    }

    /// SPEC-002 §4.4：HIPS 弹窗字段解锁的一次性「人在场」认证——同样**不建立**会话。
    /// 解锁范围由调用方的 `HipsFieldUnlock`（绑定 request_id）控制，仅当前弹窗有效，
    /// 与 History 的 5 分钟解锁会话完全隔离。
    public func authenticateForFieldUnlock(reason: String) async -> Bool {
        await evaluate(reason: reason)
    }

    private func evaluate(reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedReason = reason

        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            logger.warning("touchid not available: \(String(describing: error), privacy: .public)")
            return false
        }

        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            logger.warning("touchid failed: \(String(describing: error), privacy: .public)")
            await GUILog.shared.warn("Touch ID 认证失败：\(error.localizedDescription)", category: "touchid")
            return false
        }
    }

    public func clearSession() {
        appState.setUnlockSession(nil)
    }

    private func observeScreenLock() {
        // P1-2：三路信号任一触发都清解锁会话（信号清单与绑定逻辑见 UnlockSessionClearBinding，
        // Core 单测锚定）。com.apple.screenIsLocked 是真锁屏（Ctrl+Cmd+Q 时屏幕仍亮，
        // screensDidSleep 不触发）；快速用户切换同样收敛回脱敏。
        assert(
            UnlockSessionClearBinding.workspaceSignalNames
                == [NSWorkspace.screensDidSleepNotification.rawValue,
                    NSWorkspace.sessionDidResignActiveNotification.rawValue],
            "UnlockSessionClearBinding 的 workspace 信号名与 AppKit 常量漂移"
        )
        UnlockSessionClearBinding.register(
            subscribe: { [weak self] name, handler in
                guard let self else { return }
                let center: NotificationCenter = UnlockSessionClearBinding.distributedSignalNames.contains(name)
                    ? DistributedNotificationCenter.default()
                    : NSWorkspace.shared.notificationCenter
                let observer = center.addObserver(
                    forName: Notification.Name(name),
                    object: nil,
                    queue: .main
                ) { _ in handler() }
                sessionClearObservers.append(observer)
            },
            clearSession: { [weak self] in
                Task { @MainActor in self?.clearSession() }
            }
        )
    }
}
