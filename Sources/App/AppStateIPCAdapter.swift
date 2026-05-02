import Foundation

/// 把 IPCRouter 的回调适配到 AppState 上。
@MainActor
public final class AppStateIPCAdapter: IPCAppStateAdapter {
    private let appState: AppState

    public init(appState: AppState) { self.appState = appState }

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

    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
