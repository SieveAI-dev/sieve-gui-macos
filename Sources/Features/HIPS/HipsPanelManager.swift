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

    /// SPEC-002 §6：失联期间用户作出的决策缓存，重连握手后由 resendDisconnectedDecisions() 遍历重发。
    private var disconnectedCache = DisconnectedDecisionCache()

    /// 追踪每个 rule_id 上次 deny 时间，5s 内再次弹同 rule → 互换按钮位置
    private var denyTracker = HipsDenyTracker()

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

    /// 重连后关闭所有 stale HIPS 弹窗（SPEC-005 §3.4）。
    public func closeAllActiveDialogs() {
        pendingQueue.removeAll()
        appState.setPendingQueueCount(0)
        if activeRequest != nil {
            closePanel(notifyDaemon: false)
        }
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
        // 渲染前置校验：单 issue 模式必须有 context
        guard req.merged || req.context != nil else {
            // 非 merged 但 context 缺失 → 视为渲染失败
            handleRenderFailure(req: req, reason: "context missing for single-issue request")
            return
        }

        activeRequest = req
        appState.setActiveRequest(req)
        visibleSince = Date()

        let panel = ensurePanel()
        // 5s 内同 rule_id 再次弹窗 → 互换按钮位置（让肌肉记忆失效）
        let swapped: Bool
        if let ruleId = req.ruleId {
            swapped = denyTracker.shouldSwapLayout(ruleId: ruleId)
        } else {
            swapped = false
        }

        let view = HipsPopupView(
            request: req,
            appState: appState,
            swappedLayout: swapped,
            onDecision: { [weak self] decision, remember, hint, phase in
                self?.handleDecision(decision: decision, remember: remember, hint: hint, phase: phase)
            },
            onCloseWithoutDecision: { [weak self] in
                self?.handleClose()
            },
            isClickSwallowed: { [weak self] in
                self?.isClickSwallowed() ?? false
            },
            onMergedDecision: { [weak self] action in
                self?.handleMergedDecision(action: action)
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

    /// 渲染失败兜底：系统通知 + IPC error -32101（gui_render_failed） + 关闭弹窗
    /// 调用点：1) 前置校验失败（context 缺失）2) 未来可扩展其他渲染异常
    func handleRenderFailure(req: HipsRequest, reason: String) {
        // 日志
        Task {
            await GUILog.shared.error("hips render failed [\(req.id)]: \(reason)", category: "hips")
        }
        // 系统通知
        NotificationCenterAdapter.shared.notifyAutoDeny(ruleTitle: req.title)
        // 发送 IPC error -32101 gui_render_failed
        Task {
            await ipcClient?.sendErrorResponse(id: req.id, error: .guiRenderFailed)
        }
        // 重置状态（不调 closePanel 以避免二次 scheduleNext 错误，直接清状态）
        activeRequest?.clearRawJSON()
        activeRequest = nil
        appState.setActiveRequest(nil)
        scheduleNext()
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
                    self.handleCountdownTimeout()
                }
            }
        }
    }

    // MARK: - Decision handling

    /// 当前是否与 daemon 失联（决定决策是直发还是入失联缓存）。
    private var isDisconnected: Bool {
        if case .disconnected = appState.daemonStatus { return true }
        return false
    }

    private func handleDecision(decision: Decision, remember: Bool, hint: String?, phase: HipsPhase) {
        guard let req = activeRequest else { return }

        // deny 时记录时间，用于 5s 内同 rule_id 弹窗时互换按钮
        if decision == .deny, let ruleId = req.ruleId {
            denyTracker.recordDeny(ruleId: ruleId)
        }

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
        let payload = PendingDecisionPayload.single(response, allowRemember: req.allowRemember)

        if isDisconnected {
            // SPEC-002 §6 场景 D：失联期间不直发，缓存到 disconnectedCache，重连握手后重发
            disconnectedCache.store(payload)
        } else {
            Task { [weak self] in
                await self?.ipcClient?.sendDecisionResponse(id: req.id, result: payload.resultJSON())
            }
        }

        recordHit(for: req, decision: decision)
        closePanel(notifyDaemon: false)
    }

    /// SPEC-002 §4.8：多 issue 合并的整体决策（按动作生成 per-issue → MergedDecisionResponse）。
    private func handleMergedDecision(action: MergedAction) {
        guard let req = activeRequest else { return }
        let perIssue = MergedDecisionBuilder.perIssues(for: req.issues, action: action)
        let merged = MergedDecisionResponse(id: req.id, perIssue: perIssue, byUser: true)
        let payload = PendingDecisionPayload.merged(merged)

        if isDisconnected {
            // 失联期间缓存，重连握手后重发（复用 §6 路径）
            disconnectedCache.store(payload)
        } else {
            Task { [weak self] in
                await self?.ipcClient?.sendDecisionResponse(id: req.id, result: payload.resultJSON())
            }
        }

        recordHit(for: req, decision: action == .denyAll ? .deny : .allow)
        closePanel(notifyDaemon: false)
    }

    /// 命中本地最近列表（决策路径终点，无论是否失联都记录用户动作）。
    private func recordHit(for req: HipsRequest, decision: Decision) {
        appState.recordHit(.init(
            ruleId: req.ruleId ?? "merged",
            action: decision == .allow ? .allow : .deny,
            direction: req.direction,
            severity: req.severity,
            occurredAt: Date(),
            auditEventId: nil
        ))
    }

    /// SPEC-002 §6：重连握手后重发失联期间缓存的全部决策（daemon 按 request_id 去重，双发安全）。
    public func resendDisconnectedDecisions() {
        let pending = disconnectedCache.drain()
        guard !pending.isEmpty else { return }
        Task { [weak self] in
            for p in pending {
                await self?.ipcClient?.sendDecisionResponse(id: p.requestId, result: p.resultJSON())
            }
        }
    }

    /// 倒计时归零：用户未在 daemon 指定时限内决策。fail-closed —— 主动向 daemon 回传「拒绝」
    /// （`by_user=false` 表示超时/回退，正是 SPEC-005 §6.2 对该字段的协议预期），而非静默关窗
    /// 让 daemon 干等自己的 default_on_timeout。merged 请求按 denyAll 回传。
    private func handleCountdownTimeout() {
        guard let req = activeRequest else { return }
        let payload: PendingDecisionPayload
        if req.merged {
            let perIssue = MergedDecisionBuilder.perIssues(for: req.issues, action: .denyAll)
            payload = .merged(MergedDecisionResponse(id: req.id, perIssue: perIssue, byUser: false))
        } else {
            let response = DecisionResponse(
                id: req.id, decision: .deny, remember: false,
                contextHint: nil, byUser: false, uiPhaseWhenClicked: .red
            )
            payload = .single(response, allowRemember: req.allowRemember)
        }
        if isDisconnected {
            // 失联期间缓存，重连握手后由 resendDisconnectedDecisions() 重发（daemon 按 request_id 去重）。
            disconnectedCache.store(payload)
        } else {
            Task { [weak self] in
                await self?.ipcClient?.sendDecisionResponse(id: req.id, result: payload.resultJSON())
            }
        }
        recordHit(for: req, decision: .deny)
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
