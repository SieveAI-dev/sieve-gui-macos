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

    nonisolated public func ipc(_ client: IPCClient, didChangeState state: IPCState) {
        Task { @MainActor in
            if case .retrying = state { IPCMonitorRingBuffer.shared.recordReconnect() }
            self.applyState(state)
        }
    }

    nonisolated public func ipc(_ client: IPCClient, didReceive incoming: IPCIncoming) {
        Task { @MainActor in
            self.recordMonitor(incoming)
            self.dispatch(incoming)
        }
    }

    nonisolated public func ipcDidHandshake(_ client: IPCClient, params: HelloParams) {
        Task { @MainActor in
            IPCMonitorRingBuffer.shared.recordHandshake()
            LiveEventsRingBuffer.shared.append(source: .ipc, level: .info, category: "ipc",
                                               message: "握手成功 daemon=\(params.daemonVersion) preset=\(params.preset.rawValue)")
            // 三路 toast 判定（SPEC-005 §3.3）
            if let kind = self.appStateAdapter?.checkAndUpdateDaemonBootId(params.daemonBootId) {
                self.toastController?.presentReconnect(kind)
            }
            self.appStateAdapter?.applyHello(params)
        }
    }

    nonisolated public func ipcDidLoseConnection(_ client: IPCClient, reason: DaemonStatus.DisconnectReason) {
        Task { @MainActor in self.appStateAdapter?.applyDisconnect(reason: reason) }
    }

    nonisolated public func ipcDidDiscardInflightOnReconnect(_ client: IPCClient) {
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
        case .request(let id, let method, let p):
            monitor.record(direction: .inbound, method: method, messageId: id, bytes: p.count)
        case .notification(let method, let p):
            // heartbeat 不记录（噪音）
            if method != "sieve.heartbeat" {
                monitor.record(direction: .inbound, method: method, messageId: nil, bytes: p.count)
            }
        case .response(let id, let r):
            monitor.record(direction: .inbound, method: "response", messageId: id, bytes: r.count)
        case .errorResponse(let id, _, _, let d):
            monitor.record(direction: .inbound, method: "error_response", messageId: id, bytes: d?.count ?? 0)
        }
    }

    private func dispatch(_ incoming: IPCIncoming) {
        switch incoming {
        case .request(let id, let method, let params):
            handleDaemonRequest(id: id, method: method, paramsData: params)
        case .notification(let method, let params):
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

    private func handleDaemonNotification(method: String, paramsData: Data) {
        switch method {
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
                    if !isEcho {
                        adapter?.applyPresetChanged(p.preset)
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
