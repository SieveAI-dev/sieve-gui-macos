import Testing
import Foundation
@testable import SieveGUICore

/// HIPS 失联期间 disconnectedCache 路径完整性测试
///
/// 注意：HipsPanelManager 是 AppKit/SwiftUI 层（不在 Package.swift swift build 范围），
/// 这里测试 Models 层 + IPCClient 的相关协议行为。

@Suite("HIPS 失联 disconnectedCache 路径")
struct HipsDisconnectedCacheTests {

    // MARK: - 1. InflightQueue clearAndDiscard → reconnectedDiscarded

    @Test("clearAndDiscard：pending waiter 收到 reconnectedDiscarded 错误")
    func inflight_clearAndDiscard_notifies_waiters() async {
        let queue = InflightQueue()
        await queue.enqueue(.init(
            id: "req-d1", method: "sieve.health",
            payload: Data(), createdAt: Date(),
            isDecisionResponse: false
        ))
        await queue.enqueue(.init(
            id: "req-d2", method: "decision_response",
            payload: Data(), createdAt: Date(),
            isDecisionResponse: true
        ))

        // 用 Task 异步 await，收集错误
        let task1 = Task<Error?, Never> {
            do {
                let _: Data = try await withCheckedThrowingContinuation { cont in
                    Task { await queue.registerWaiter(id: "req-d1", continuation: cont) }
                }
                return nil
            } catch {
                return error
            }
        }
        let task2 = Task<Error?, Never> {
            do {
                let _: Data = try await withCheckedThrowingContinuation { cont in
                    Task { await queue.registerWaiter(id: "req-d2", continuation: cont) }
                }
                return nil
            } catch {
                return error
            }
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        await queue.clearAndDiscard()

        let err1 = await task1.value
        let err2 = await task2.value

        #expect(err1 != nil, "req-d1 waiter 应收到错误")
        #expect(err2 != nil, "req-d2 waiter 应收到错误")

        if let e1 = err1 as? InflightQueue.AwaitError {
            #expect(e1 == .reconnectedDiscarded)
        }
        if let e2 = err2 as? InflightQueue.AwaitError {
            #expect(e2 == .reconnectedDiscarded)
        }

        let count = await queue.count()
        #expect(count == 0, "clearAndDiscard 后 queue 应为空")
    }

    // MARK: - 2. default_on_timeout 三值解码（block/allow/redact）

    @Test("default_on_timeout 解码：block / allow / redact")
    func default_on_timeout_all_values() throws {
        let cases: [(String, DefaultOnTimeout)] = [
            ("block", .block),
            ("allow", .allow),
            ("redact", .redact)
        ]
        for (raw, expected) in cases {
            let json = """
            {
              "request_id": "req-dot-\(raw)",
              "timeout_seconds": 30,
              "default_on_timeout": "\(raw)",
              "allow_remember": false,
              "merged": false,
              "direction": "outbound",
              "severity": "high",
              "title": "Test \(raw)",
              "rule_id": "OUT-07",
              "context": {"template": "generic_json", "payload": {}}
            }
            """
            let req = try HipsRequestDecoder.decode(id: "id-\(raw)", paramsData: Data(json.utf8))
            #expect(req.defaultOnTimeout == expected, "'\(raw)' 应解码为 .\(raw)")
        }
    }

    // MARK: - 3. decision_response inflight 高优先级排序

    @Test("isDecisionResponse=true 的 inflight 排序在前")
    func decision_response_priority_sort() async {
        let queue = InflightQueue()
        await queue.enqueue(.init(
            id: "normal", method: "sieve.health",
            payload: Data(), createdAt: Date(timeIntervalSinceNow: -10),
            isDecisionResponse: false
        ))
        await queue.enqueue(.init(
            id: "decision", method: "decision_response",
            payload: Data(), createdAt: Date(),  // 更晚创建但高优先级
            isDecisionResponse: true
        ))
        let pending = await queue.allPending()
        #expect(pending.count == 2)
        #expect(pending[0].id == "decision", "isDecisionResponse=true 应排序在前")
    }

    // MARK: - 4. 重连后 delegate 收到 ipcDidDiscardInflightOnReconnect

    @Test("重连后 ipcDidDiscardInflightOnReconnect 被调用")
    func reconnect_triggers_discard_delegate() async throws {
        let daemon = MockDaemonHarness()
        try daemon.start()
        defer { daemon.stop() }

        let delegate = TestIPCDelegate()
        let client = IPCClient(delegate: delegate, socketPath: daemon.socketPath)
        client.connect()
        defer { client.disconnect() }

        // 建立连接 + hello
        _ = await delegate.waitForState(.connected, timeout: 3.0)
        daemon.sendHello(daemonBootId: "boot-disc-1")
        _ = await delegate.waitForHandshake(timeout: 3.0)

        // 断开并等待 IPCClient 检测到断连
        daemon.disconnectClient()
        try await Task.sleep(nanoseconds: 400_000_000)

        // 重新发送 hello（重连场景）
        daemon.sendHello(daemonBootId: "boot-disc-2")

        // 验证 ipcDidDiscardInflightOnReconnect 被调用
        let discarded = await delegate.waitForDiscardedCount(min: 1, timeout: 5.0)
        #expect(discarded, "重连后 ipcDidDiscardInflightOnReconnect 应被触发")
    }

    // MARK: - 5. 失联后 versionMismatch 时 inflight 全部 fail

    @Test("versionMismatch 时 disconnectedCache 中的 inflight 全部 fail")
    func versionMismatch_fails_all_inflight() async throws {
        let daemon = MockDaemonHarness()
        try daemon.start()
        defer { daemon.stop() }

        let delegate = TestIPCDelegate()
        let client = IPCClient(delegate: delegate, socketPath: daemon.socketPath)
        client.connect()
        defer { client.disconnect() }

        _ = await delegate.waitForState(.connected, timeout: 3.0)

        // 发起一个 inflight request（不会收到响应）
        let taskResult = Task<Error?, Never> {
            do {
                _ = try await client.sendRequest(id: "req-vm-disc", method: "sieve.health")
                return nil
            } catch {
                return error
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        // 发送版本不匹配的 hello → inflight 全部 fail
        daemon.sendHello(protocolVersion: "v99")

        let err = await taskResult.value
        #expect(err != nil, "versionMismatch 后 inflight 应失败")
        if let awaitErr = err as? InflightQueue.AwaitError {
            #expect(awaitErr == .versionMismatch)
        }
    }
}
