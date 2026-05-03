import Testing
import Foundation
@testable import SieveGUICore

// MARK: - 测试 Delegate

/// 收集 IPCClient 回调事件，供测试断言
final class TestIPCDelegate: IPCDelegate, @unchecked Sendable {
    private let lock = NSLock()

    private var _states: [IPCState] = []
    private var _handshakeParams: [HelloParams] = []
    private var _incomings: [IPCIncoming] = []
    private var _disconnectReasons: [DaemonStatus.DisconnectReason] = []
    private var _discardedCount: Int = 0

    var states: [IPCState] { lock.withLock { _states } }
    var handshakeParams: [HelloParams] { lock.withLock { _handshakeParams } }
    var incomings: [IPCIncoming] { lock.withLock { _incomings } }
    var disconnectReasons: [DaemonStatus.DisconnectReason] { lock.withLock { _disconnectReasons } }
    var discardedCount: Int { lock.withLock { _discardedCount } }

    var latestState: IPCState? { lock.withLock { _states.last } }
    var latestHandshake: HelloParams? { lock.withLock { _handshakeParams.last } }

    // 等待特定状态的续延
    private var stateWaiters: [(IPCState, CheckedContinuation<Void, Never>)] = []

    func waitForState(_ target: IPCState, timeout: TimeInterval = 5.0) async -> Bool {
        // 已经到了目标状态
        if lock.withLock({ _states.contains(target) }) { return true }

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // Swift Testing 不支持 withCheckedThrowingContinuation 超时内嵌，用简单轮询替代
            Task {
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if self.lock.withLock({ self._states.contains(target) }) {
                        cont.resume(returning: true)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                }
                cont.resume(returning: false)
            }
        }
    }

    /// 等到 handshakeParams.count 严格大于 `after` 时返回最新一条；用于多次握手场景区分新旧
    func waitForHandshake(after: Int = 0, timeout: TimeInterval = 5.0) async -> HelloParams? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snapshot = lock.withLock { _handshakeParams }
            if snapshot.count > after { return snapshot.last }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    func waitForDiscardedCount(min: Int, timeout: TimeInterval = 5.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ _discardedCount }) >= min { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    // MARK: - IPCDelegate

    nonisolated func ipc(_ client: IPCClient, didChangeState state: IPCState) {
        lock.withLock { _states.append(state) }
    }

    nonisolated func ipc(_ client: IPCClient, didReceive incoming: IPCIncoming) {
        lock.withLock { _incomings.append(incoming) }
    }

    nonisolated func ipcDidHandshake(_ client: IPCClient, params: HelloParams) {
        lock.withLock { _handshakeParams.append(params) }
    }

    nonisolated func ipcDidLoseConnection(_ client: IPCClient, reason: DaemonStatus.DisconnectReason) {
        lock.withLock { _disconnectReasons.append(reason) }
    }

    nonisolated func ipcDidDiscardInflightOnReconnect(_ client: IPCClient) {
        lock.withLock { _discardedCount += 1 }
    }
}

// MARK: - 集成测试套件

@Suite("IPCClient 集成测试（mock daemon harness）")
struct IPCClientIntegrationTests {

    // MARK: - Test 1: 握手成功路径

    @Test("握手成功：mock daemon 发 v2 hello → IPCClient 进入 active 状态")
    func handshake_success() async throws {
        let daemon = MockDaemonHarness()
        try daemon.start()
        defer { daemon.stop() }

        let delegate = TestIPCDelegate()
        let client = IPCClient(delegate: delegate, socketPath: daemon.socketPath)
        client.connect()
        defer { client.disconnect() }

        // 等 IPCClient 连接到 mock daemon（connected 状态）
        let connected = await delegate.waitForState(.connected, timeout: 3.0)
        #expect(connected, "IPCClient 应进入 connected 状态")

        // 发送 hello
        let bootId = UUID().uuidString
        daemon.sendHello(daemonBootId: bootId)

        // 等待 active 状态 + handshake 回调
        let gotHandshake = await delegate.waitForHandshake(timeout: 3.0)
        #expect(gotHandshake != nil, "应收到 ipcDidHandshake 回调")
        #expect(gotHandshake?.protocolVersion == "v2")
        #expect(gotHandshake?.daemonBootId == bootId)
        #expect(gotHandshake?.daemonVersion == "0.9.0-test")

        let isActive = await delegate.waitForState(.active, timeout: 3.0)
        #expect(isActive, "握手后 IPCClient 应进入 active 状态")
    }

    // MARK: - Test 2: 协议版本不识别 → terminal + 不重连

    @Test("协议版本不识别：v99 hello → versionMismatch terminal + inflight 全 fail")
    func version_mismatch_terminal() async throws {
        let daemon = MockDaemonHarness()
        try daemon.start()
        defer { daemon.stop() }

        let delegate = TestIPCDelegate()
        let client = IPCClient(delegate: delegate, socketPath: daemon.socketPath)
        client.connect()
        defer { client.disconnect() }

        // 等连接建立
        let connected = await delegate.waitForState(.connected, timeout: 3.0)
        #expect(connected)

        // 启动一个 inflight 请求（在 hello 之前，让它挂在那里）
        let requestTask = Task<Result<Data, Error>, Never> {
            do {
                let data = try await client.sendRequest(id: "req-vm-1", method: "sieve.health")
                return .success(data)
            } catch {
                return .failure(error)
            }
        }

        // 短暂等待请求入队
        try await Task.sleep(nanoseconds: 100_000_000)

        // 发送 v99 hello
        daemon.sendHello(protocolVersion: "v99")

        // 等待 versionMismatch 状态
        let gotMismatch = await delegate.waitForState(
            .versionMismatch(received: "v99"),
            timeout: 3.0
        )
        #expect(gotMismatch, "应进入 versionMismatch terminal 状态")

        // inflight 请求应收到 versionMismatch 错误
        let result = await requestTask.value
        switch result {
        case .failure(let err):
            if let awaitErr = err as? InflightQueue.AwaitError {
                #expect(awaitErr == .versionMismatch, "inflight 应收到 .versionMismatch 错误")
            } else {
                Issue.record("错误类型应为 InflightQueue.AwaitError，实际：\(err)")
            }
        case .success:
            Issue.record("versionMismatch 后 inflight 应失败，不应成功")
        }

        // 验证不再重连：versionMismatch 之后不应出现 connecting / retrying
        // （初始连接时 connecting / connected 是合法过渡，只查 versionMismatch 之后的尾部）
        try await Task.sleep(nanoseconds: 500_000_000)
        let states = delegate.states
        let mismatchIdx = states.firstIndex { if case .versionMismatch = $0 { return true }; return false }
        #expect(mismatchIdx != nil, "应至少出现一次 versionMismatch 状态")
        if let idx = mismatchIdx {
            let tail = Array(states[(idx + 1)...])
            #expect(!tail.contains(.connecting), "versionMismatch 后不应再尝试重连（connecting）")
            let hasRetrying = tail.contains { if case .retrying = $0 { return true }; return false }
            #expect(!hasRetrying, "versionMismatch 后不应有 retrying 状态")
        }
    }

    // MARK: - Test 3: 重连丢 inflight（SPEC-005 §3.4）

    @Test("重连丢 inflight：发送请求 → 断开 → 重连 → waiter 收到 reconnectedDiscarded")
    func reconnect_discards_inflight() async throws {
        let daemon = MockDaemonHarness()
        try daemon.start()
        defer { daemon.stop() }

        let delegate = TestIPCDelegate()
        let client = IPCClient(delegate: delegate, socketPath: daemon.socketPath)
        client.connect()
        defer { client.disconnect() }

        // 等连接 + hello
        let connected = await delegate.waitForState(.connected, timeout: 3.0)
        #expect(connected)
        daemon.sendHello()
        let gotHandshake = await delegate.waitForHandshake(timeout: 3.0)
        #expect(gotHandshake != nil)

        // 发送一个 request（不会得到响应）
        let requestTask = Task<Result<Data, Error>, Never> {
            do {
                let data = try await client.sendRequest(id: "req-rc-1", method: "sieve.health")
                return .success(data)
            } catch {
                return .failure(error)
            }
        }
        try await Task.sleep(nanoseconds: 150_000_000)  // 让请求入队

        // 断开连接（模拟 daemon 重启）
        let connBefore = daemon.connectionCount
        daemon.disconnectClient()

        // 等 IPCClient 退避重连成功（退避 1/2/5/10/30s，首次 1s+ 即可）
        let reconnected = await daemon.waitForNewConnection(after: connBefore, timeout: 8.0)
        #expect(reconnected, "IPCClient 应在 8s 内重连成功（退避序列 1/2/5/10/30s）")
        daemon.sendHello(daemonBootId: UUID().uuidString)

        // 等待 ipcDidDiscardInflightOnReconnect 回调
        let discarded = await delegate.waitForDiscardedCount(min: 1, timeout: 5.0)
        #expect(discarded, "重连后应调用 ipcDidDiscardInflightOnReconnect")

        // inflight 请求应收到 reconnectedDiscarded 错误
        let result = await requestTask.value
        switch result {
        case .failure(let err):
            if let awaitErr = err as? InflightQueue.AwaitError {
                #expect(awaitErr == .reconnectedDiscarded, "应收到 .reconnectedDiscarded 错误")
            }
            // 也可能是 .canceled（连接关闭），视为通过
        case .success:
            Issue.record("断连重连后 inflight 应失败，不应成功")
        }
    }

    // MARK: - Test 4: daemon_boot_id 三路场景

    @Test("daemon_boot_id 三路：首次连接 / boot_id 变化（重启）/ boot_id 相同（仅断连）")
    func daemon_boot_id_three_paths() async throws {
        let daemon = MockDaemonHarness()
        try daemon.start()
        defer { daemon.stop() }

        let delegate = TestIPCDelegate()
        let client = IPCClient(delegate: delegate, socketPath: daemon.socketPath)
        client.connect()
        defer { client.disconnect() }

        // ── 路径 1：首次连接 ──
        let bootId1 = UUID().uuidString
        _ = await delegate.waitForState(.connected, timeout: 3.0)
        daemon.sendHello(daemonBootId: bootId1)
        let h1 = await delegate.waitForHandshake(timeout: 3.0)
        #expect(h1 != nil, "路径 1：应收到 handshake")
        #expect(h1?.daemonBootId == bootId1)
        let handshakeCount1 = delegate.handshakeParams.count
        #expect(handshakeCount1 == 1, "路径 1：handshake 次数应为 1")

        // ── 路径 2：boot_id 变化（daemon 重启）──
        let conn1 = daemon.connectionCount
        daemon.disconnectClient()
        // 等 IPCClient 退避重连成功（退避 1/2/5/10/30s，首次 1s+ 即可）
        let reconnected2 = await daemon.waitForNewConnection(after: conn1, timeout: 8.0)
        #expect(reconnected2, "路径 2：IPCClient 应在 8s 内重连成功")
        let bootId2 = UUID().uuidString  // 新 boot_id
        daemon.sendHello(daemonBootId: bootId2)
        let h2 = await delegate.waitForHandshake(after: handshakeCount1, timeout: 5.0)
        #expect(h2 != nil, "路径 2：重启后应再次收到 handshake")
        #expect(h2?.daemonBootId == bootId2, "路径 2：boot_id 应是新值")
        let handshakeCount2 = delegate.handshakeParams.count

        // ── 路径 3：boot_id 相同（仅断连，非 daemon 重启）──
        let conn2 = daemon.connectionCount
        daemon.disconnectClient()
        let reconnected3 = await daemon.waitForNewConnection(after: conn2, timeout: 8.0)
        #expect(reconnected3, "路径 3：IPCClient 应在 8s 内重连成功")
        daemon.sendHello(daemonBootId: bootId2)  // 相同 boot_id
        let h3 = await delegate.waitForHandshake(after: handshakeCount2, timeout: 5.0)
        #expect(h3 != nil, "路径 3：仅断连重连也应收到 handshake")
        #expect(h3?.daemonBootId == bootId2, "路径 3：boot_id 应保持不变")
    }

    // MARK: - Test 5: request_decision 单 issue + merged 双格式解码

    @Test("request_decision 格式：单 issue + merged 双格式可被 IPCIncoming 解码")
    func request_decision_decode_both_formats() async throws {
        let daemon = MockDaemonHarness()
        try daemon.start()
        defer { daemon.stop() }

        let delegate = TestIPCDelegate()
        let client = IPCClient(delegate: delegate, socketPath: daemon.socketPath)
        client.connect()
        defer { client.disconnect() }

        _ = await delegate.waitForState(.connected, timeout: 3.0)
        daemon.sendHello()
        _ = await delegate.waitForHandshake(timeout: 3.0)

        // ── 单 issue 格式 ──
        let singleIssueParams: [String: Any] = [
            "request_id": "req-single-1",
            "timeout_seconds": 30,
            "default_on_timeout": "block",
            "allow_remember": true,
            "merged": false,
            "direction": "outbound",
            "severity": "high",
            "title": "Test Request",
            "rule_id": "OUT-07",
            "context": [
                "template": "generic_json",
                "payload": ["key": "value"]
            ]
        ]
        daemon.sendRequest(
            id: "req-single-1",
            method: "sieve.request_decision",
            params: singleIssueParams
        )

        // 等待 delegate 收到 incoming
        let deadline1 = Date().addingTimeInterval(3.0)
        while Date() < deadline1 {
            if delegate.incomings.contains(where: {
                if case .request(_, let method, _) = $0, method == "sieve.request_decision" { return true }
                return false
            }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let singleReceived = delegate.incomings.contains {
            if case .request(_, let method, _) = $0, method == "sieve.request_decision" { return true }
            return false
        }
        #expect(singleReceived, "应收到单 issue request_decision")

        // ── merged 格式 ──
        let mergedParams: [String: Any] = [
            "request_id": "req-merged-1",
            "timeout_seconds": 30,
            "default_on_timeout": "block",
            "allow_remember": false,
            "merged": true,
            "direction": "outbound",
            "severity": "critical",
            "title": "Merged Request",
            "issues": [
                [
                    "issue_id": "iss-1",
                    "rule_id": "OUT-07",
                    "title": "Issue 1",
                    "severity": "high",
                    "allow_remember": false,
                    "context": ["template": "generic_json", "payload": ["x": 1]]
                ],
                [
                    "issue_id": "iss-2",
                    "rule_id": "OUT-08",
                    "title": "Issue 2",
                    "severity": "critical",
                    "allow_remember": false,
                    "context": ["template": "generic_json", "payload": ["y": 2]]
                ]
            ]
        ]
        daemon.sendRequest(
            id: "req-merged-1",
            method: "sieve.request_decision",
            params: mergedParams
        )

        let deadline2 = Date().addingTimeInterval(3.0)
        while Date() < deadline2 {
            let count = delegate.incomings.filter {
                if case .request(_, let m, _) = $0, m == "sieve.request_decision" { return true }
                return false
            }.count
            if count >= 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let requestDecisionCount = delegate.incomings.filter {
            if case .request(_, let m, _) = $0, m == "sieve.request_decision" { return true }
            return false
        }.count
        #expect(requestDecisionCount >= 2, "应收到两条 request_decision（单 + merged）")

        // 验证 merged 格式可被 HipsRequestDecoder 解析
        let mergedIncoming = delegate.incomings.first {
            if case .request(let id, _, _) = $0, id == "req-merged-1" { return true }
            return false
        }
        #expect(mergedIncoming != nil, "merged request 应被收到")

        if case .request(_, _, let paramsData) = mergedIncoming! {
            let decoded = try? HipsRequestDecoder.decode(id: "req-merged-1", paramsData: paramsData)
            #expect(decoded != nil, "merged request_decision 应可被 HipsRequestDecoder 解码")
            #expect(decoded?.merged == true, "解码后 merged 字段应为 true")
            #expect(decoded?.issues.count == 2, "merged 请求应有 2 个 issues")
        }
    }
}
