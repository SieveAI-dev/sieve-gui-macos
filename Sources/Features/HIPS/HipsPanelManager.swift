import AppKit
import SwiftUI
import Combine

/// HIPS 浮窗单例管理器。
/// - 复用一个 NSPanel（隐藏态常驻，弹出时只切内容不重建）
/// - 串行排队：同一时刻只显示一个弹窗
/// - 失联期间决策缓存到 disconnectedCache，重连后由 IPCClient 自动重发 inflight
@MainActor
public final class HipsPanelManager: NSObject, IPCHipsAdapter {
    public static let shared = HipsPanelManager()

    private weak var ipcClient: IPCClient?
    private let appState = AppState.shared

    private var panel: HipsPanel?
    private var hostingController: NSHostingController<HipsPopupView>?
    private var pendingQueue: [HipsRequest] = []
    public private(set) var activeRequest: HipsRequest?

    /// 失联期间用户已经做出的决策，待重连后批量重发（IPCClient inflight 也会兜底，这里冗余防丢）
    private var disconnectedCache: [(id: String, payload: () async -> Void)] = []

    private var countdownTimer: Timer?
    private var visibleSince: Date?

    public func install(ipcClient: IPCClient) {
        self.ipcClient = ipcClient
    }

    // MARK: - IPCHipsAdapter

    public func enqueueRequest(_ req: HipsRequest) {
        pendingQueue.append(req)
        appState.setPendingQueueCount(pendingQueue.count)
        scheduleNext()
    }

    public func cancelRequest(id: String, reason: String) {
        // 移除 pending
        pendingQueue.removeAll { $0.id == id }
        appState.setPendingQueueCount(pendingQueue.count)
        // 关闭活动弹窗
        if activeRequest?.id == id {
            closePanel(notifyDaemon: false)
        }
    }

    public func failRequest(id: String, error: DecisionError) {
        Task {
            await ipcClient?.sendErrorResponse(id: id, error: error)
        }
        if activeRequest?.id == id { closePanel(notifyDaemon: false) }
    }

    // MARK: - Queue

    private func scheduleNext() {
        guard activeRequest == nil, let next = pendingQueue.first else { return }
        pendingQueue.removeFirst()
        appState.setPendingQueueCount(pendingQueue.count)
        present(next)
    }

    // MARK: - Present

    private func present(_ req: HipsRequest) {
        activeRequest = req
        appState.setActiveRequest(req)
        visibleSince = Date()

        let panel = ensurePanel()
        let view = HipsPopupView(
            request: req,
            appState: appState,
            onDecision: { [weak self] decision, remember, hint, phase in
                self?.handleDecision(decision: decision, remember: remember, hint: hint, phase: phase)
            },
            onCloseWithoutDecision: { [weak self] in
                self?.handleClose()
            },
            isClickSwallowed: { [weak self] in
                self?.isClickSwallowed() ?? false
            }
        )
        let host = hostingController ?? NSHostingController(rootView: view)
        host.rootView = view
        if hostingController == nil { hostingController = host }
        panel.contentViewController = host
        panel.title = req.title
        centerOnActiveScreen(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        startCountdown()
    }

    private func ensurePanel() -> HipsPanel {
        if let p = panel { return p }
        let p = HipsPanel.makeFloatingPanel()
        panel = p
        return p
    }

    private func centerOnActiveScreen(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        panel.setFrameOrigin(origin)
    }

    private var countdownRemaining: Int = 0

    private func startCountdown() {
        countdownTimer?.invalidate()
        guard let req = activeRequest else { return }
        countdownRemaining = req.timeoutSeconds
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            // Timer 回调线程性约束：scheduledTimer 在当前 RunLoop（这里是主线程）触发，self 已 MainActor。
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.countdownRemaining -= 1
                if self.countdownRemaining <= 0 {
                    self.countdownTimer?.invalidate()
                    self.closePanel(notifyDaemon: false)
                }
            }
        }
    }

    // MARK: - Decision handling

    private func handleDecision(decision: Decision, remember: Bool, hint: String?, phase: HipsPhase) {
        guard let req = activeRequest else { return }

        // 编码层强制：allow_remember=false 时永远 false
        let safeRemember = req.allowRemember ? remember : false

        let response = DecisionResponse(
            id: req.id,
            decision: decision,
            remember: safeRemember,
            contextHint: hint,
            byUser: true,   // 用户主动点按钮触发
            uiPhaseWhenClicked: phase
        )

        Task { [weak self] in
            await self?.ipcClient?.sendDecisionResponse(id: req.id, result: response.resultJSON(allowRemember: req.allowRemember))
            // 命中本地最近列表
            await MainActor.run {
                self?.appState.recordHit(.init(
                    ruleId: req.ruleId ?? "merged",
                    action: decision == .allow ? .allow : .deny,
                    direction: req.direction,
                    severity: req.severity,
                    occurredAt: Date(),
                    auditEventId: nil
                ))
            }
        }

        closePanel(notifyDaemon: false)
    }

    private func handleClose() {
        guard let req = activeRequest else { return }
        // 用户主动关闭 → -32100
        Task { [weak self] in
            await self?.ipcClient?.sendErrorResponse(id: req.id, error: .userCanceledViaWindowClose)
        }
        closePanel(notifyDaemon: false)
    }

    private func closePanel(notifyDaemon: Bool) {
        countdownTimer?.invalidate()
        countdownTimer = nil
        visibleSince = nil

        // 红线：清空 rawJSON
        activeRequest?.clearRawJSON()
        activeRequest = nil
        appState.setActiveRequest(nil)

        panel?.orderOut(nil)
        // 不销毁 panel；下次复用

        // 出队下一个
        scheduleNext()
    }

    // MARK: - Click swallow

    /// 弹窗弹出后 400ms 内所有按钮 swallow（防误触）。
    public func isClickSwallowed() -> Bool {
        guard let visibleSince = visibleSince else { return false }
        return Date().timeIntervalSince(visibleSince) < 0.4
    }
}

/// NSPanel 子类 — 配置 floating + .canJoinAllSpaces + .fullScreenAuxiliary。
public final class HipsPanel: NSPanel {
    public static func makeFloatingPanel() -> HipsPanel {
        let style: NSWindow.StyleMask = [.titled, .closable, .nonactivatingPanel]
        let p = HipsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.hidesOnDeactivate = false
        p.titlebarAppearsTransparent = false
        p.isMovableByWindowBackground = true
        return p
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}
