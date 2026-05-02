import AppKit
import SwiftUI

/// 唯一窗口打开入口（[ADR-003](docs/design/adr/ADR-003-window-scene-model.md)）。
/// 不允许使用 `@Environment(\.openWindow)`。
@MainActor
public final class WindowManager: NSObject {
    public static let shared = WindowManager()

    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var debugWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var historyVM: HistoryWindowViewModel?

    public weak var ipcClient: IPCClient?

    public func openSettings() {
        if let w = settingsWindow { focus(w); return }
        let view = SettingsWindowView(appState: AppState.shared, ipcClient: ipcClient ?? IPCClient())
        let host = NSHostingController(rootView: view)
        let w = makeWindow(title: "Sieve 设置", contentVC: host, size: NSSize(width: 720, height: 540))
        settingsWindow = w
        focus(w)
    }

    public func openHistory() {
        if let w = historyWindow { focus(w); return }
        let reader = AuditDBReader()
        let vm = HistoryWindowViewModel(reader: reader)
        historyVM = vm
        let view = HistoryWindowView(viewModel: vm, appState: AppState.shared)
        let host = NSHostingController(rootView: view)
        let w = makeWindow(title: "Sieve 历史", contentVC: host, size: NSSize(width: 1080, height: 660))
        historyWindow = w
        focus(w)
    }

    public func openDebug() {
        if let w = debugWindow { focus(w); return }
        let view = DebugWindowView(appState: AppState.shared, ipcClient: ipcClient ?? IPCClient())
        let host = NSHostingController(rootView: view)
        let w = makeWindow(title: "Sieve 调试", contentVC: host, size: NSSize(width: 960, height: 600))
        debugWindow = w
        focus(w)
    }

    private var onboardingSession: NSApplication.ModalSession?

    public func openOnboarding() {
        if onboardingWindow != nil { return }
        let view = OnboardingView(
            appState: AppState.shared,
            ipcClient: ipcClient ?? IPCClient(),
            onClose: { [weak self] in self?.closeOnboarding() }
        )
        let host = NSHostingController(rootView: view)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled],   // 禁用最小化/最大化/关闭（关闭走 onClose 走 alert 路径）
            backing: .buffered,
            defer: false
        )
        w.title = "Sieve 引导"
        w.contentViewController = host
        w.center()
        w.isReleasedWhenClosed = false
        onboardingWindow = w

        // 使用 runModalSession 不阻塞主 RunLoop（ADR-003 / SPEC-006）
        let session = NSApp.beginModalSession(for: w)
        onboardingSession = session
        // 模态轮询：每 100ms 用 runModalSession 喂一次事件，让其他主线程任务（IPC/audit）不饿死
        scheduleModalPump(session: session)
    }

    private func scheduleModalPump(session: NSApplication.ModalSession) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self, self.onboardingSession != nil else { return }
            let result = NSApp.runModalSession(session)
            if result == .continue {
                self.scheduleModalPump(session: session)
            } else {
                self.cleanupOnboardingSession()
            }
        }
    }

    private func cleanupOnboardingSession() {
        if let s = onboardingSession {
            NSApp.endModalSession(s)
            onboardingSession = nil
        }
        onboardingWindow?.orderOut(nil)
        onboardingWindow = nil
    }

    private func closeOnboarding() {
        guard let w = onboardingWindow else { return }
        if let s = onboardingSession {
            NSApp.endModalSession(s)
            onboardingSession = nil
        }
        w.close()
        onboardingWindow = nil
    }

    private func makeWindow(title: String, contentVC: NSViewController, size: NSSize) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.contentViewController = contentVC
        w.center()
        w.isReleasedWhenClosed = false
        return w
    }

    private func focus(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
