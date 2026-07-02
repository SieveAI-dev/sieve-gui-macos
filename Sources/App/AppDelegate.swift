import AppKit
import os.log
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.sieve.gui", category: "app")
    private let ipcClient = IPCClient()
    private var ipcAdapter: AppStateIPCAdapter?

    public func applicationDidFinishLaunching(_: Notification) {
        // 1. 初始化 AppState（已由 .shared 触发）
        let appState = AppState.shared

        // 1a. GUILog tail → LiveEvents ring buffer
        GUILog.tail = { entry in
            Task { @MainActor in
                let level: LiveEventsRingBuffer.Entry.Level = {
                    switch entry.level { case "WARN": return .warn; case "ERROR": return .error; default: return .info }
                }()
                LiveEventsRingBuffer.shared.append(
                    source: .gui,
                    level: level,
                    category: entry.category,
                    message: entry.message
                )
            }
        }

        // 2. 装配 IPC router
        let adapter = AppStateIPCAdapter(appState: appState)
        ipcAdapter = adapter
        IPCRouter.shared.appStateAdapter = adapter
        IPCRouter.shared.hipsManager = HipsPanelManager.shared
        IPCRouter.shared.toastController = ToastController.shared
        ipcClient.delegate = IPCRouter.shared
        // 回声判定依赖此引用：preset_changed / paused_changed 通知经 IPCRouter 用
        // ipcClient.isMutatingEcho 判断是否为本 GUI 自己发出的变更回声。漏装配 → 恒 nil
        // → isMutatingEcho 恒 false → 本地乐观更新会被 daemon 回声二次 apply（paused 回跳）。
        IPCRouter.shared.ipcClient = ipcClient
        HipsPanelManager.shared.install(ipcClient: ipcClient)
        WindowManager.shared.ipcClient = ipcClient

        // 3. 启动 IPC（异步）
        ipcClient.connect()

        // 4. 菜单栏
        MenuBarController.shared.install(ipcClient: ipcClient)

        // 5. audit.db 后台 watch → LiveEvents
        startAuditWatching()

        // 6. Onboarding 检查
        if appState.settings.onboardingCompletedAt == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                WindowManager.shared.openOnboarding()
            }
        }

        Task { await GUILog.shared.info("Sieve GUI 启动", category: "app") }
    }

    private var auditReader: AuditDBReader?
    private let lastSeenCursor = LastSeenCursor()

    private func startAuditWatching() {
        let reader = AuditDBReader()
        do {
            try reader.open()
            auditReader = reader
            let cursor = lastSeenCursor
            Task { await cursor.set(reader.maxId()) }
            reader.startWatching {
                Task {
                    let from = await cursor.value
                    let new = reader.incrementalEvents(sinceId: from, limit: 50)
                    guard !new.isEmpty else { return }
                    await cursor.set(new.last?.id ?? from)
                    await MainActor.run {
                        for ev in new {
                            LiveEventsRingBuffer.shared.append(
                                source: .audit, level: .info,
                                category: ev.disposition,
                                message: "#\(ev.id) \(ev.ruleId) sev=\(ev.severity.rawValue) dir=\(ev.direction.rawValue)"
                            )
                        }
                    }
                }
            }
        } catch {
            Task { await GUILog.shared.warn("audit.db 打开失败：\(error)", category: "audit") }
        }
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false // LSUIElement，关闭最后一个窗口不退出
    }

    public func applicationWillTerminate(_: Notification) {
        // 通知 daemon 当前 inflight 决策被中断
        // IPCClient 内部 inflight 在重启后会自动重发；这里只记日志
        Task { await GUILog.shared.info("Sieve GUI 退出", category: "app") }
    }
}

actor LastSeenCursor {
    private(set) var value: Int64 = 0
    func set(_ v: Int64) {
        value = v
    }
}
