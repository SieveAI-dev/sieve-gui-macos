import AppKit
import SwiftUI

/// 唯一窗口打开入口（窗口场景模型）。
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

    /// 解析注入的 ipcClient。正常路径 AppDelegate 已注入并强持有；若 weak 链意外断裂，
    /// debug 下 assert 暴露（避免静默 new 一个未 connect 的孤儿 client 让窗口请求进黑洞）。
    private func resolvedIPCClient() -> IPCClient {
        if let c = ipcClient { return c }
        assertionFailure("WindowManager.ipcClient 未注入 — 窗口内 IPC 请求将无响应")
        return IPCClient()
    }

    public func openSettings() {
        if let w = settingsWindow { focus(w); return }
        let view = SettingsWindowView(appState: AppState.shared, ipcClient: resolvedIPCClient())
        let host = NSHostingController(rootView: view)
        let w = makeWindow(title: "Sieve 设置", contentVC: host, size: NSSize(width: 720, height: 540))
        settingsWindow = w
        focus(w)
    }

    public func openHistory(requestId: String? = nil) {
        if let w = historyWindow {
            focus(w)
            if let requestId { historyVM?.selectAndReveal(requestId: requestId) }
            return
        }
        let reader = AuditDBReader()
        let vm = HistoryWindowViewModel(reader: reader)
        historyVM = vm
        let view = HistoryWindowView(viewModel: vm, appState: AppState.shared)
        let host = NSHostingController(rootView: view)
        let w = makeWindow(title: "Sieve 历史", contentVC: host, size: NSSize(width: 1080, height: 660))
        historyWindow = w
        focus(w)
        if let requestId {
            // View.onAppear 会先 open reader；下一轮 RunLoop 再执行精确定位。
            DispatchQueue.main.async { vm.selectAndReveal(requestId: requestId) }
        }
    }

    public func openDebug() {
        if let w = debugWindow { focus(w); return }
        let view = DebugWindowView(appState: AppState.shared, ipcClient: resolvedIPCClient())
            .environmentObject(DebugReplayStore.shared)
        let host = NSHostingController(rootView: view)
        let w = makeWindow(title: "Sieve 调试", contentVC: host, size: NSSize(width: 960, height: 600))
        debugWindow = w
        focus(w)
    }

    /// History Inspector → Debug RuleEvaluation Tab 重放入口。
    /// 设置 prefilledPrompt → 打开/聚焦 Debug 窗口。
    /// RuleEvaluationTab.onAppear 会读取并填入 payload textarea。
    public func replayInDebug(prompt: String) {
        DebugReplayStore.shared.setPrefilled(prompt)
        openDebug()
    }

    private var onboardingSession: NSApplication.ModalSession?
    private var onboardingCloseDelegate: OnboardingCloseDelegate?
    /// 关闭按钮回调的桥：OnboardingView 注册自己的 confirmSkip 进来，窗口关闭按钮复用之。
    private let onboardingSkipBridge = OnboardingSkipBridge()

    public func openOnboarding() {
        if onboardingWindow != nil { return }
        let view = OnboardingView(
            appState: AppState.shared,
            ipcClient: resolvedIPCClient(),
            skipBridge: onboardingSkipBridge,
            onClose: { [weak self] in self?.closeOnboarding() }
        )
        let host = NSHostingController(rootView: view)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            // SPEC-006 §4.1：关闭按钮存在，但点击不直接关，走确认 alert（windowShouldClose）。
            // 禁用最小化/最大化，不可调整大小。
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Sieve 引导"
        w.contentViewController = host
        w.center()
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        onboardingWindow = w

        // 拦截关闭按钮：弹确认 alert，复用 Onboarding 的「跳过」语义（写完成时间戳 + 记录跳过步骤）。
        let delegate = OnboardingCloseDelegate { [weak self] in self?.confirmCloseOnboarding() }
        onboardingCloseDelegate = delegate
        w.delegate = delegate

        // 使用 runModalSession 不阻塞主 RunLoop（SPEC-006）
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
        w.delegate = nil
        onboardingCloseDelegate = nil
        w.close()
        onboardingWindow = nil
    }

    /// 标题栏关闭按钮点击 → 复用 OnboardingView.confirmSkip（弹确认 alert、记录跳过步骤、写完成时间戳）。
    /// 若 bridge 尚未注册（极早期），退化为直接关闭。
    private func confirmCloseOnboarding() {
        if let skip = onboardingSkipBridge.confirmSkip {
            skip()
        } else {
            closeOnboarding()
        }
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

/// OnboardingView 把自身 confirmSkip 注册进来，供窗口关闭按钮复用（避免重复 alert 逻辑）。
@MainActor
public final class OnboardingSkipBridge {
    public var confirmSkip: (() -> Void)?
    public init() {}
}

/// Onboarding 窗口的关闭按钮拦截：返回 false 阻止系统直接关窗，转交 onClose 走确认 alert。
final class OnboardingCloseDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose()
        return false
    }
}
