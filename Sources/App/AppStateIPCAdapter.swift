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
            case .redacted: return .redact
            case .statusMarked: return .marked
            case .hookTerminal: return .terminal
            }
        }()
        let hit = HitSummary(
            ruleId: params.ruleId,
            action: action,
            direction: params.direction,
            severity: params.severity,
            occurredAt: parseDate(params.occurredAt) ?? Date(),
            auditEventId: params.auditEventId
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

    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
