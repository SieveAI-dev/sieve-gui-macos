import Foundation

/// 把 IPCRouter 的回调适配到 AppState 上。
@MainActor
public final class AppStateIPCAdapter: IPCAppStateAdapter {
    private let appState: AppState
    private let store: UserSettingsStore

    public init(appState: AppState, store: UserSettingsStore = UserSettingsStore()) {
        self.appState = appState
        self.store = store
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
    }

    public func applyDisconnect(reason: DaemonStatus.DisconnectReason) {
        appState.applyDisconnect(reason: reason)
    }

    public func applyEventNotify(_ params: EventNotifyParams) {
        let action: HitSummary.Action = {
            switch params.kind {
            case .outboundRedacted: return .redact
            case .hookTerminal: return .terminal
            case .sequenceHit, .userRulesLoadFailed, .userRulesReloaded: return .marked
            case .generic: return .allow
            }
        }()
        // StatusBarNotify wire（SPEC-005 §10.1）不含 direction/severity；
        // 由 kind 派生展示语义（仅菜单栏命中摘要用，非决策路径）。
        let direction: Direction = (params.kind == .outboundRedacted) ? .outbound : .inbound
        let severity: Severity = {
            switch params.kind {
            case .userRulesLoadFailed: return .high
            case .outboundRedacted, .hookTerminal, .sequenceHit: return .medium
            case .userRulesReloaded, .generic: return .low
            }
        }()
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
