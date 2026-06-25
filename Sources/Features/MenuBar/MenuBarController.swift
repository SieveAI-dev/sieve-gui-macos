import AppKit
import SwiftUI
import Combine

/// 菜单栏 controller。管理 NSStatusItem 与 Quick Menu popover。
@MainActor
public final class MenuBarController: NSObject, NSPopoverDelegate {
    public static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    private weak var ipcClient: IPCClient?
    private let appState = AppState.shared

    public func install(ipcClient: IPCClient) {
        self.ipcClient = ipcClient
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusBarIcon.image(for: appState.daemonStatus)
        item.button?.action = #selector(togglePopover(_:))
        item.button?.target = self
        item.button?.imagePosition = .imageLeading
        statusItem = item

        bindAppState()
    }

    private func bindAppState() {
        appState.$daemonStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.statusItem?.button?.image = StatusBarIcon.image(for: status)
                self?.statusItem?.button?.toolTip = StatusBarIcon.accessibilityLabel(for: status)
            }
            .store(in: &cancellables)

        appState.$holdRemainingSeconds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] secs in
                self?.updateHoldBadge(secs)
            }
            .store(in: &cancellables)

        appState.$warningHitCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.updateWarningBadge(count)
            }
            .store(in: &cancellables)
    }

    private func updateHoldBadge(_ secs: Int) {
        guard let button = statusItem?.button else { return }
        if case .hold = appState.daemonStatus, secs > 0 {
            button.title = " " + String(format: "%ds", secs)
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        } else {
            // hold 结束后不能无条件清空 title——否则会抹掉 warning 角标且不会恢复
            // （warning sink 仅在 warningHitCount 变化时触发）。回退重算 warning 角标。
            updateWarningBadge(appState.warningHitCount)
        }
    }

    private func updateWarningBadge(_ count: Int) {
        guard let button = statusItem?.button else { return }
        if appState.holdRemainingSeconds > 0 { return }
        if count > 0 {
            button.title = " " + (count > 99 ? "99+" : "\(count)")
            button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        } else {
            button.title = ""
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if let pop = popover, pop.isShown {
            pop.performClose(sender)
            return
        }
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        let pop = popover ?? buildPopover()
        popover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func buildPopover() -> NSPopover {
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self
        let view = QuickMenuView(
            appState: appState,
            onOpenSettings: { [weak self] in self?.openWindow(.settings) },
            onOpenHistory: { [weak self] in self?.openWindow(.history) },
            onOpenDebug: { [weak self] in self?.openWindow(.debug) },
            onOpenOnboarding: { [weak self] in self?.openWindow(.onboarding) },
            onPause: { [weak self] minutes in self?.requestPause(minutes: minutes) },
            onResume: { [weak self] in self?.requestResume() },
            onQuit: { [weak self] in self?.confirmQuit() }
        )
        let host = NSHostingController(rootView: view)
        host.view.frame = NSRect(x: 0, y: 0, width: 320, height: 360)
        p.contentViewController = host
        return p
    }

    // MARK: - Actions

    private enum WindowKind { case settings, history, debug, onboarding }

    private func openWindow(_ kind: WindowKind) {
        popover?.performClose(nil)
        switch kind {
        case .settings: WindowManager.shared.openSettings()
        case .history: WindowManager.shared.openHistory()
        case .debug: WindowManager.shared.openDebug()
        case .onboarding: WindowManager.shared.openOnboarding()
        }
    }

    private func requestPause(minutes: Int) {
        let bounded = max(1, min(30, minutes))
        let pauseId = UUID().uuidString
        // 乐观更新：先按本地估算 until 切到 paused
        let optimisticUntil = Date().addingTimeInterval(TimeInterval(bounded * 60))
        appState.updatePaused(true, until: optimisticUntil)
        Task { [weak self] in
            guard let self = self, let client = self.ipcClient else { return }
            await client.registerMutatingRequest(pauseId)   // 注册先于发送，避免 echo 漏判
            do {
                let data = try await client.sendRequest(
                    id: pauseId,
                    method: "sieve.set_paused",
                    params: SetPausedParams(minutes: bounded)
                )
                client.unregisterMutatingRequest(pauseId)
                if let resp = try? JSONDecoder().decode(SetPausedResult.self, from: data),
                   let until = resp.pausedUntil {
                    await MainActor.run { self.appState.updatePaused(true, until: until) }
                }
            } catch {
                client.unregisterMutatingRequest(pauseId)
                // 失败 → 回滚
                await MainActor.run { self.appState.updatePaused(false, until: nil) }
                await GUILog.shared.warn("set_paused 失败：\(error)", category: "menubar")
            }
        }
    }

    private func requestResume() {
        let resumeId = UUID().uuidString
        appState.updatePaused(false, until: nil)
        Task { [weak self] in
            guard let self = self, let client = self.ipcClient else { return }
            await client.registerMutatingRequest(resumeId)   // 注册先于发送，避免 echo 漏判
            client.sendRequestAndForget(
                id: resumeId,
                method: "sieve.set_paused",
                params: SetPausedParams(minutes: 0)
            )
            // fire-and-forget 无法 await 结果，延迟 10s 后自动反注册（避免集合永久增长）
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            client.unregisterMutatingRequest(resumeId)
        }
    }

    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "退出 Sieve GUI？"
        alert.informativeText = "退出后 daemon 仍会继续运行，但你将看不到 HIPS 弹窗与状态栏图标。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }
}
