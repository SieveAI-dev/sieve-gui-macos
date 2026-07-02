import Foundation
import Testing
@testable import SieveGUICore

@Suite("IPCMonitorRingBuffer — 详情面板字段 + params 不渲染")
@MainActor
struct IPCMonitorRingBufferTests {
    @Test("记录消息包含 method / messageId / bytes / timestamp")
    func record_contains_expected_fields() {
        let buf = IPCMonitorRingBuffer()
        let before = Date()
        buf.record(direction: .inbound, method: "sieve.hello", messageId: "msg-001", bytes: 512)
        let after = Date()

        #expect(buf.entries.count == 1)
        let e = buf.entries[0]
        #expect(e.method == "sieve.hello")
        #expect(e.messageId == "msg-001")
        #expect(e.bytes == 512)
        #expect(e.direction == .inbound)
        #expect(e.timestamp >= before)
        #expect(e.timestamp <= after)
    }

    @Test("Entry 不含 params 字段（硬红线 SPEC-005）")
    func entry_has_no_params_field() {
        let buf = IPCMonitorRingBuffer()
        buf.record(direction: .outbound, method: "sieve.evaluate", messageId: "m-2", bytes: 1024)
        let e = buf.entries[0]
        // 通过 Mirror 检查：Entry 不应有 "params" 属性
        let mirror = Mirror(reflecting: e)
        let hasParams = mirror.children.contains { $0.label == "params" }
        #expect(!hasParams, "IPCMonitorRingBuffer.Entry 不应包含 params 字段")
    }

    @Test("ring buffer 容量上限：超出后丢弃旧条目")
    func ring_buffer_capacity_limit() {
        let buf = IPCMonitorRingBuffer()
        for i in 0 ..< (IPCMonitorRingBuffer.capacity + 10) {
            buf.record(direction: .inbound, method: "m-\(i)", messageId: nil, bytes: i)
        }
        #expect(buf.entries.count == IPCMonitorRingBuffer.capacity)
    }

    @Test("recordHandshake / recordReconnect 计数正确")
    func counters_increment() {
        let buf = IPCMonitorRingBuffer()
        buf.recordHandshake()
        buf.recordHandshake()
        buf.recordReconnect()
        #expect(buf.handshakeCount == 2)
        #expect(buf.reconnectCount == 1)
    }
}
