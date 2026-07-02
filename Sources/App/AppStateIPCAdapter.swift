import Foundation

/// 把 IPCRouter 的回调适配到 AppState 上。
@MainActor
public final class AppStateIPCAdapter: IPCAppStateAdapter {
    private let appState: AppState
    private let store: UserSettingsStore
    private let notifier: NotificationCenterAdapter

    /// 失联通知去抖位：applyDisconnect 由 IPCClient 在 attempt>=3 才经 ipcDidLoseConnection
    /// 触发（已是去抖后信号），但重试期间可能重复调用 —— 用此位保证一次失联只发一条系统
    /// 通知，并作为「是否需要在重连时补发恢复通知」的依据（首次连接不发恢复通知）。
    private var disconnectNotified = false

    public init(appState: AppState,
                store: UserSettingsStore = UserSettingsStore(),
                notifier: NotificationCenterAdapter = .shared)
    {
        self.appState = appState
        self.store = store
        self.notifier = notifier
    }

    public func applyIPCState(_ state: IPCState) {
        switch state {
        case .versionMismatch:
            appState.applyDisconnect(reason: .versionMismatch)
        case .retrying:
            // 多次重试后才标记 disconnected（IPCClient 内部判定 attempt >= 3 调 ipcDidLoseConnection）
            break
        case .active:
            appState.markConnected()
        default:
            break
        }
    }

    public func applyHello(_ params: HelloParams) {
        appState.applyHello(params)
        // 握手成功 = 权威的「已连接」信号（硬约束 #6：菜单栏状态以 sieve.hello 为准）。
        // 仅当此前真正发过失联通知时才补发恢复通知，避免首次连接误报「已重连」。
        if disconnectNotified {
            disconnectNotified = false
            notifier.notifyReconnected()
        }
    }

    public func applyDisconnect(reason: DaemonStatus.DisconnectReason) {
        appState.applyDisconnect(reason: reason)
        // 此回调由 IPCClient 在 attempt>=3 经 ipcDidLoseConnection 触发，已是去抖后的失联事实。
        // 去抖位保证一次失联只发一条系统通知（重试期间重复调用不重复打扰）。
        guard !disconnectNotified else { return }
        disconnectNotified = true
        notifier.notifyDisconnected(reason: reason)
    }

    public func applyEventNotify(_ params: EventNotifyParams) {
        let action: HitSummary.Action = switch params.kind {
        case .outboundRedacted: .redact
        case .hookTerminal: .terminal
        case .sequenceHit, .userRulesLoadFailed, .userRulesReloaded: .marked
        case .generic: .allow
        }
        // StatusBarNotify wire（SPEC-005 §10.1）不含 direction/severity；
        // 由 kind 派生展示语义（仅菜单栏命中摘要用，非决策路径）。
        let direction: Direction = (params.kind == .outboundRedacted) ? .outbound : .inbound
        let severity: Severity = switch params.kind {
        case .userRulesLoadFailed: .high
        case .outboundRedacted, .hookTerminal, .sequenceHit: .medium
        case .userRulesReloaded, .generic: .low
        }
        let hit = HitSummary(
            ruleId: params.ruleId ?? params.kind.rawValue,
            action: action,
            direction: direction,
            severity: severity,
            occurredAt: params.createdAt,
            auditEventId: nil
        )
        appState.recordHit(hit)
    }

    public func applyPresetChanged(_ preset: Preset) {
        appState.updatePreset(preset)
    }

    public func applyPausedChanged(_ params: PausedChangedParams) {
        appState.updatePaused(params.paused, until: params.pausedUntil)
    }

    public func checkAndUpdateDaemonBootId(_ bootId: String) -> ReconnectKind? {
        let last = store.lastSeenDaemonBootId()
        store.setLastSeenDaemonBootId(bootId)
        guard let last else {
            // 首次连接，无 toast
            return nil
        }
        if last != bootId {
            return .daemonRestarted
        } else {
            return .reconnected
        }
    }
}
