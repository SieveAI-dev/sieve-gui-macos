import SwiftUI
import AppKit

@main
struct SieveGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 使用 Settings scene 作为占位（LSUIElement = true，没有主窗口）。
        // 真实窗口由 WindowManager 用 NSWindow 直接管理。
        Settings { EmptyView() }
    }
}
