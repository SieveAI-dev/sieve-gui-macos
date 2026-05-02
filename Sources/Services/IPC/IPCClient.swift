import Foundation
import Network
import os.log

public enum IPCState: Equatable, Sendable {
    case idle
    case connecting
    case connected            // 已建立 socket，未握手
    case active               // 收到 sieve.hello，可正常通信
    case retrying(after: TimeInterval, attempt: Int)
    case versionMismatch(received: String)
}

public protocol IPCDelegate: AnyObject, Sendable {
    func ipc(_ client: IPCClient, didChangeState state: IPCState)
    func ipc(_ client: IPCClient, didReceive incoming: IPCIncoming)
    func ipcDidHandshake(_ client: IPCClient, params: HelloParams)
    func ipcDidLoseConnection(_ client: IPCClient, reason: DaemonStatus.DisconnectReason)
}

/// GUI 侧 IPC 客户端。线程模型：
/// - `NWConnection` 在 `ipcQueue` 上跑，所有 socket I/O 不阻塞主线程
/// - 状态变更通过 `Task { @MainActor }` 投递到 delegate（delegate 必须在 MainActor 处理）
public final class IPCClient: @unchecked Sendable {
    public static let socketPath: String = NSHomeDirectory() + "/.sieve/ipc.sock"
    public static let supportedProtocolVersions: Set<String> = ["v2"]

    private static let backoff: [TimeInterval] = [1, 2, 5, 10, 30]
    private static let heartbeatTimeout: TimeInterval = 30
    private static let maxMessageBytes: Int = 1024 * 1024

    public weak var delegate: IPCDelegate?

    private let ipcQueue = DispatchQueue(label: "com.sieve.gui.ipc", qos: .userInitiated)
    private let inflight = InflightQueue()
    private let logger = Logger(subsystem: "com.sieve.gui", category: "ipc")

    private var connection: NWConnection?
    private var state: IPCState = .idle {
        didSet { notifyState(state) }
    }
    private var attempt: Int = 0
    private var heartbeatTask: DispatchWorkItem?
    private var lastReceivedAt: Date = .distantPast
    private var receiveBuffer = Data()
    private var shouldReconnect = true

    public init(delegate: IPCDelegate? = nil) {
        self.delegate = delegate
    }

    // MARK: - Public API

    public func connect() {
        ipcQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.connection == nil else { return }
            self.shouldReconnect = true
            self.openConnection()
        }
    }

    public func disconnect() {
        ipcQueue.async { [weak self] in
            guard let self = self else { return }
            self.shouldReconnect = false
            self.tearDown()
            self.state = .idle
        }
    }

    /// 发送一条请求并 await daemon 响应（result 数据）。
    /// daemon 返回 error 响应 → 抛 `InflightQueue.AwaitError.rpcError`。
    /// 协议版本不识别 / 失联终态 → 抛 `AwaitError.versionMismatch / .canceled`。
    public func sendRequest(id: String, method: String, params: [String: Any]? = nil) async throws -> Data {
        let data = IPCOutbound.request(id: id, method: method, params: params)
        await inflight.enqueue(.init(
            id: id, method: method, payload: data,
            createdAt: Date(),
            isDecisionResponse: false
        ))
        sendRaw(data)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            Task { await self.inflight.registerWaiter(id: id, continuation: cont) }
        }
    }

    /// fire-and-forget 版本（不关心响应，只送出去）。
    public func sendRequestAndForget(id: String, method: String, params: [String: Any]? = nil) {
        let data = IPCOutbound.request(id: id, method: method, params: params)
        Task { await self.inflight.enqueue(.init(
            id: id, method: method, payload: data,
            createdAt: Date(), isDecisionResponse: false)) }
        sendRaw(data)
    }

    /// 发送 decision_response：必须用 result 形式，且 inflight 标记高优先级。
    public func sendDecisionResponse(id: String, result: [String: Any]) async {
        let data = IPCOutbound.response(id: id, result: result)
        await inflight.enqueue(.init(
            id: id, method: "decision_response", payload: data,
            createdAt: Date(),
            isDecisionResponse: true
        ))
        sendRaw(data)
    }

    public func sendErrorResponse(id: String, error: DecisionError) async {
        let data = IPCOutbound.errorResponse(id: id, code: error.code, message: error.message)
        await inflight.enqueue(.init(
            id: id, method: "decision_error", payload: data,
            createdAt: Date(),
            isDecisionResponse: true
        ))
        sendRaw(data)
    }

    public func sendNotification(method: String, params: [String: Any]? = nil) {
        let data = IPCOutbound.notification(method: method, params: params)
        sendRaw(data)
    }

    public var currentState: IPCState {
        ipcQueue.sync { state }
    }

    // MARK: - Connection lifecycle

    private func openConnection() {
        let path = IPCClient.socketPath
        guard FileManager.default.fileExists(atPath: path) else {
            logger.warning("ipc socket missing at \(path, privacy: .public)")
            scheduleRetry(reason: .socketMissing)
            return
        }

        let endpoint = NWEndpoint.unix(path: path)
        let conn = NWConnection(to: endpoint, using: .tcp)
        // .tcp 在 unix domain 下被 Network.framework 视为 stream — 我们只需 stream 语义
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            self?.handleNWState(newState)
        }
        state = .connecting
        conn.start(queue: ipcQueue)
        startHeartbeatTimer()
        receiveLoop()
    }

    private func handleNWState(_ nwState: NWConnection.State) {
        switch nwState {
        case .ready:
            attempt = 0
            state = .connected
            lastReceivedAt = Date()
        case .failed(let err), .waiting(let err):
            logger.warning("nw state failed/waiting: \(String(describing: err), privacy: .public)")
            tearDown()
            scheduleRetry(reason: .socketMissing)
        case .cancelled:
            tearDown()
        default:
            break
        }
    }

    private func tearDown() {
        connection?.cancel()
        connection = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveBuffer.removeAll()
    }

    private func scheduleRetry(reason: DaemonStatus.DisconnectReason) {
        guard shouldReconnect else { return }
        // versionMismatch 是 terminal，不重连
        if case .versionMismatch = state { return }

        attempt += 1
        let idx = min(attempt - 1, IPCClient.backoff.count - 1)
        let delay = IPCClient.backoff[idx]
        state = .retrying(after: delay, attempt: attempt)
        if attempt >= 3 {
            notifyDisconnect(reason: reason)
        }
        ipcQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.shouldReconnect else { return }
            self.openConnection()
        }
    }

    // MARK: - Receive loop

    private func receiveLoop() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let error = error {
                self.logger.error("ipc receive error: \(String(describing: error), privacy: .public)")
                self.tearDown()
                self.scheduleRetry(reason: .heartbeatTimeout)
                return
            }
            if let data = data, !data.isEmpty {
                self.lastReceivedAt = Date()
                self.receiveBuffer.append(data)
                self.drainBuffer()
            }
            if isComplete {
                self.tearDown()
                self.scheduleRetry(reason: .daemonShutdown)
                return
            }
            self.receiveLoop()
        }
    }

    private func drainBuffer() {
        while let nl = receiveBuffer.firstIndex(of: 0x0A) {
            let line = receiveBuffer.subdata(in: receiveBuffer.startIndex..<nl)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex...nl)
            if line.isEmpty { continue }
            if line.count > IPCClient.maxMessageBytes {
                logger.error("ipc message too large: \(line.count, privacy: .public) bytes")
                tearDown()
                scheduleRetry(reason: .unknown)
                return
            }
            do {
                let incoming = try IPCIncoming.decode(line: line)
                handleIncoming(incoming)
            } catch {
                logger.warning("ipc decode error: \(String(describing: error), privacy: .public) — line dropped, connection kept")
            }
        }
        // 缓冲区单条消息也限制大小（防御性）
        if receiveBuffer.count > IPCClient.maxMessageBytes {
            logger.error("ipc inbound buffer exceeded; closing")
            tearDown()
            scheduleRetry(reason: .unknown)
        }
    }

    private func handleIncoming(_ incoming: IPCIncoming) {
        // 优先处理握手与 inflight
        if case .notification(let method, let params) = incoming, method == "sieve.hello" {
            handleHello(params: params)
        }
        if case .response(let id, let result) = incoming {
            Task { await inflight.fulfill(id: id, resultData: result) }
        }
        if case .errorResponse(let id, let code, let msg, let edata) = incoming {
            Task { await inflight.reject(id: id, code: code, message: msg, data: edata) }
        }
        // 投递主线程
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.delegate?.ipc(self, didReceive: incoming)
        }
    }

    private func handleHello(params: Data) {
        do {
            let hello = try JSONDecoder().decode(HelloParams.self, from: params)
            guard IPCClient.supportedProtocolVersions.contains(hello.protocolVersion) else {
                logger.error("ipc protocol_version mismatch: \(hello.protocolVersion, privacy: .public)")
                state = .versionMismatch(received: hello.protocolVersion)
                shouldReconnect = false
                Task { await self.inflight.failAll(error: .versionMismatch) }
                tearDown()
                notifyDisconnect(reason: .versionMismatch)
                return
            }
            state = .active
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.delegate?.ipcDidHandshake(self, params: hello)
            }
            // 重连后重发 inflight
            Task { [weak self] in
                guard let self = self else { return }
                let pending = await self.inflight.allPending()
                for entry in pending {
                    self.sendRaw(entry.payload)
                }
            }
        } catch {
            logger.error("ipc hello decode failed: \(String(describing: error), privacy: .public)")
            tearDown()
            scheduleRetry(reason: .unknown)
        }
    }

    // MARK: - Send

    private func sendRaw(_ data: Data) {
        ipcQueue.async { [weak self] in
            guard let self = self, let conn = self.connection else { return }
            conn.send(content: data, completion: .contentProcessed { [weak self] err in
                if let err = err {
                    self?.logger.warning("ipc send error: \(String(describing: err), privacy: .public)")
                }
            })
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeatTimer() {
        heartbeatTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.checkHeartbeat() }
        heartbeatTask = task
        ipcQueue.asyncAfter(deadline: .now() + 5, execute: task)
    }

    private func checkHeartbeat() {
        let now = Date()
        if now.timeIntervalSince(lastReceivedAt) > IPCClient.heartbeatTimeout {
            logger.warning("ipc heartbeat timeout")
            tearDown()
            scheduleRetry(reason: .heartbeatTimeout)
            return
        }
        startHeartbeatTimer()
    }

    // MARK: - Notifications

    private func notifyState(_ state: IPCState) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.delegate?.ipc(self, didChangeState: state)
        }
    }

    private func notifyDisconnect(reason: DaemonStatus.DisconnectReason) {
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.delegate?.ipcDidLoseConnection(self, reason: reason)
        }
    }
}
