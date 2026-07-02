import Foundation
import os.log

/// 把 IPCClient 的原始消息分发到 AppState / 各 Manager。MainActor。
@MainActor
public final class IPCRouter: IPCDelegate {
    public static let shared = IPCRouter()

    private let logger = Logger(subsystem: "com.sieve.gui", category: "ipc-router")
    public weak var appStateAdapter: IPCAppStateAdapter?
    public weak var hipsManager: IPCHipsAdapter?
    public weak var toastController: IPCToastAdapter?
    public weak var ipcClient: IPCClient?

    private init() {}

    // MARK: - IPCDelegate

    public nonisolated func ipc(_: IPCClient, didChangeState state: IPCState) {
        Task { @MainActor in
            if case .retrying = state { IPCMonitorRingBuffer.shared.recordReconnect() }
            self.applyState(state)
        }
    }

    public nonisolated func ipc(_: IPCClient, didReceive incoming: IPCIncoming) {
        Task { @MainActor in
            self.recordMonitor(incoming)
            self.dispatch(incoming)
        }
    }

    public nonisolated func ipcDidHandshake(_: IPCClient, params: HelloParams) {
        Task { @MainActor in
            IPCMonitorRingBuffer.shared.recordHandshake()
            LiveEventsRingBuffer.shared.append(source: .ipc, level: .info, category: "ipc",
                                               message: "握手成功 daemon=\(params.daemonVersion) preset=\(params.preset.rawValue)")
            // 三路 toast 判定（SPEC-005 §3.3）
            if let kind = self.appStateAdapter?.checkAndUpdateDaemonBootId(params.daemonBootId) {
                self.toastController?.presentReconnect(kind)
            }
            self.appStateAdapter?.applyHello(params)
            // SPEC-002 §6：握手成功 → 重发失联期间用户已作出的决策
            self.hipsManager?.resendDisconnectedDecisions()
        }
    }

    public nonisolated func ipcDidLoseConnection(_: IPCClient, reason: DaemonStatus.DisconnectReason) {
        Task { @MainActor in self.appStateAdapter?.applyDisconnect(reason: reason) }
    }

    public nonisolated func ipcDidDiscardInflightOnReconnect(_: IPCClient) {
        Task { @MainActor in
            self.hipsManager?.closeAllActiveDialogs()
        }
    }

    private func applyState(_ state: IPCState) {
        appStateAdapter?.applyIPCState(state)
    }

    private func recordMonitor(_ incoming: IPCIncoming) {
        let monitor = IPCMonitorRingBuffer.shared
        switch incoming {
        case let .request(id, method, p):
            monitor.record(direction: .inbound, method: method, messageId: id, bytes: p.count)
        case let .notification(method, p):
            // heartbeat 不记录（噪音）
            if method != "sieve.heartbeat" {
                monitor.record(direction: .inbound, method: method, messageId: nil, bytes: p.count)
            }
        case let .response(id, r):
            monitor.record(direction: .inbound, method: "response", messageId: id, bytes: r.count)
        case let .errorResponse(id, _, _, d):
            monitor.record(direction: .inbound, method: "error_response", messageId: id, bytes: d?.count ?? 0)
        }
    }

    private func dispatch(_ incoming: IPCIncoming) {
        switch incoming {
        case let .request(id, method, params):
            handleDaemonRequest(id: id, method: method, paramsData: params)
        case let .notification(method, params):
            handleDaemonNotification(method: method, paramsData: params)
        case .response, .errorResponse:
            break // 由具体调用方通过 inflight 处理（未来扩展回调）
        }
    }

    private func handleDaemonRequest(id: String, method: String, paramsData: Data) {
        switch method {
        case "sieve.request_decision":
            do {
                let req = try HipsRequestDecoder.decode(id: id, paramsData: paramsData)
                hipsManager?.enqueueRequest(req)
            } catch {
                logger.error("decode request_decision failed: \(String(describing: error), privacy: .public)")
                hipsManager?.failRequest(id: id, error: .guiRenderFailed)
            }
        default:
            logger.notice("unhandled request method: \(method, privacy: .public)")
        }
    }

    /// internal（非 private）：单测直接驱动通知路由（P1-4 回归锚定）。
    func handleDaemonNotification(method: String, paramsData: Data) {
        switch method {
        case "sieve.reload_user_rules":
            // P1-4：用户/CLI 经 daemon 改规则 → 通知打开中的规则总览刷新（原先落 default 被丢弃）
            NotificationCenter.default.post(name: .sieveUserRulesReloaded, object: nil)
        case "sieve.heartbeat":
            return // 已在 IPCClient 层刷新 lastReceivedAt
        case "sieve.hello":
            return // 已在 IPCClient 层处理
        case "sieve.request_decision_canceled":
            if let p = try? JSONDecoder().decode(RequestCanceledParams.self, from: paramsData) {
                hipsManager?.cancelRequest(id: p.requestId, reason: p.reason)
            }
        case "sieve.notify_status_bar":
            if let p = try? JSONDecoder().decode(EventNotifyParams.self, from: paramsData) {
                appStateAdapter?.applyEventNotify(p)
                toastController?.presentEvent(p)
            }
        case "sieve.preset_changed":
            if let p = try? JSONDecoder().decode(PresetChangedParams.self, from: paramsData) {
                let client = ipcClient
                let adapter = appStateAdapter
                Task { @MainActor in
                    let isEcho = await client?.isMutatingEcho(originRequestId: p.originRequestId) ?? false
                    // daemon 只发 mode(String)（SPEC-005 §10.1，无独立 preset 字段）；
                    // 映射到 Preset enum，未知值忽略（不污染状态）。
                    if !isEcho, let preset = Preset(rawValue: p.mode) {
                        adapter?.applyPresetChanged(preset)
                    }
                }
            }
        case "sieve.paused_changed":
            if let p = try? JSONDecoder().decode(PausedChangedParams.self, from: paramsData) {
                let client = ipcClient
                let adapter = appStateAdapter
                Task { @MainActor in
                    let isEcho = await client?.isMutatingEcho(originRequestId: p.originRequestId) ?? false
                    if !isEcho {
                        adapter?.applyPausedChanged(p)
                    }
                }
            }
        default:
            logger.notice("unhandled notification: \(method, privacy: .public)")
        }
    }
}

// MARK: - Adapters（避免直接依赖具体类型，便于测试 + 解耦）

@MainActor
public protocol IPCAppStateAdapter: AnyObject {
    func applyIPCState(_ state: IPCState)
    func applyHello(_ params: HelloParams)
    func applyDisconnect(reason: DaemonStatus.DisconnectReason)
    func applyEventNotify(_ params: EventNotifyParams)
    func applyPresetChanged(_ preset: Preset)
    func applyPausedChanged(_ params: PausedChangedParams)
    /// 对比并更新 lastSeenDaemonBootId，返回重连类型（nil = 首次连接）。
    func checkAndUpdateDaemonBootId(_ bootId: String) -> ReconnectKind?
}

@MainActor
public protocol IPCHipsAdapter: AnyObject {
    func enqueueRequest(_ req: HipsRequest)
    func cancelRequest(id: String, reason: String)
    func failRequest(id: String, error: DecisionError)
    /// 重连后关闭所有 active HIPS 弹窗（避免 stale UI，SPEC-005 §3.4）。
    func closeAllActiveDialogs()
    /// SPEC-002 §6：重连握手成功后，重发失联期间缓存的全部决策（daemon 按 request_id 去重）。
    func resendDisconnectedDecisions()
}

public extension Notification.Name {
    /// P1-4：daemon 通知用户规则已重载（`sieve.reload_user_rules`）→ 规则总览刷新。
    static let sieveUserRulesReloaded = Notification.Name("com.sieve.gui.userRulesReloaded")
}

public enum ReconnectKind: Sendable {
    /// 连接中断后重连（daemon 未重启）
    case reconnected
    /// daemon 已重启（boot_id 不同）
    case daemonRestarted
}

@MainActor
public protocol IPCToastAdapter: AnyObject {
    func presentEvent(_ params: EventNotifyParams)
    func presentReconnect(_ kind: ReconnectKind)
}
