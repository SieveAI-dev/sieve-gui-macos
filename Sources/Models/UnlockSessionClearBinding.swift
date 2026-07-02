import Foundation

/// 解锁会话清除的信号 → 动作绑定（P1-2，订阅函数可注入，单测锚定）。
///
/// 真正的锁屏事件是分布式通知 `com.apple.screenIsLocked`——Ctrl+Cmd+Q 锁屏时屏幕
/// 仍亮，`screensDidSleep` 不触发（旧实现只挂它，名不副实）。三路信号任一触发都清会话：
/// 锁屏 / 显示器睡眠 / 快速用户切换。
public enum UnlockSessionClearBinding {
    /// 分布式通知（DistributedNotificationCenter）：真锁屏事件。
    public static let distributedSignalNames = ["com.apple.screenIsLocked"]

    /// NSWorkspace 通知：显示器睡眠 / 快速用户切换（rawValue 与 AppKit 常量一致，
    /// TouchIDService 注册处有编译期断言对齐）。
    public static let workspaceSignalNames = [
        "NSWorkspaceScreensDidSleepNotification",
        "NSWorkspaceSessionDidResignActiveNotification"
    ]

    public static var allSignalNames: [String] {
        distributedSignalNames + workspaceSignalNames
    }

    /// 用注入的 subscribe 给每个信号名挂 handler；任一信号触发 → clearSession。
    public static func register(
        subscribe: (_ signalName: String, _ handler: @escaping @Sendable () -> Void) -> Void,
        clearSession: @escaping @Sendable () -> Void
    ) {
        for name in allSignalNames {
            subscribe(name) { clearSession() }
        }
    }
}
