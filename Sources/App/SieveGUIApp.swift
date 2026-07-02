import AppKit
import SwiftUI

@main
struct SieveGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 使用 Settings scene 作为占位（LSUIElement = true，没有主窗口）。
        // 真实窗口由 WindowManager 用 NSWindow 直接管理。
        Settings { EmptyView() }
            .commands {
                CommandGroup(after: .appInfo) {
                    Button("历史…") { WindowManager.shared.openHistory() }
                        .keyboardShortcut("l", modifiers: .command)
                    Button("调试…") { WindowManager.shared.openDebug() }
                        .keyboardShortcut("d", modifiers: [.command, .option])
                }
                CommandGroup(replacing: .appSettings) {
                    Button("设置…") { WindowManager.shared.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(replacing: .appTermination) {
                    Button("退出 Sieve GUI") { MenuBarController.shared.confirmQuit() }
                        .keyboardShortcut("q", modifiers: .command)
                }
            }
    }
}
