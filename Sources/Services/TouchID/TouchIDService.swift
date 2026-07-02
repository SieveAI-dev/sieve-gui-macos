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
    private var screenLockObserver: NSObjectProtocol?

    override public init() {
        super.init()
        observeScreenLock()
    }

    public func authenticate(reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedReason = reason

        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            logger.warning("touchid not available: \(String(describing: error), privacy: .public)")
            return false
        }

        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok {
                appState.setUnlockSession(UnlockSession())
                await GUILog.shared.info("Touch ID 解锁成功，会话有效 5 分钟", category: "touchid")
            }
            return ok
        } catch {
            logger.warning("touchid failed: \(String(describing: error), privacy: .public)")
            await GUILog.shared.warn("Touch ID 解锁失败：\(error.localizedDescription)", category: "touchid")
            return false
        }
    }

    public func clearSession() {
        appState.setUnlockSession(nil)
    }

    private func observeScreenLock() {
        let nc = NSWorkspace.shared.notificationCenter
        screenLockObserver = nc.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.clearSession() }
        }
    }
}
