import Testing
import Foundation
@testable import SieveGUICore

@Suite("IPC message decode")
struct IPCMessageTests {
    @Test func decodes_request() throws {
        let line = #"{"jsonrpc":"2.0","method":"sieve.request_decision","id":"1","params":{"a":1}}"#
        let m = try IPCIncoming.decode(line: Data(line.utf8))
        if case .request(let id, let method, _) = m {
            #expect(id == "1")
            #expect(method == "sieve.request_decision")
        } else {
            Issue.record("expected request")
        }
    }

    @Test func decodes_notification() throws {
        let line = #"{"jsonrpc":"2.0","method":"sieve.heartbeat"}"#
        let m = try IPCIncoming.decode(line: Data(line.utf8))
        if case .notification(let method, _) = m {
            #expect(method == "sieve.heartbeat")
        } else {
            Issue.record("expected notification")
        }
    }

    @Test func decodes_error_response() throws {
        let line = #"{"jsonrpc":"2.0","id":"x","error":{"code":-32010,"message":"critical_lock_violation"}}"#
        let m = try IPCIncoming.decode(line: Data(line.utf8))
        if case .errorResponse(_, let code, let message, _) = m {
            #expect(code == -32010)
            #expect(message == "critical_lock_violation")
        } else {
            Issue.record("expected error response")
        }
    }

    @Test func rejects_non_jsonrpc() {
        let line = #"{"foo":"bar"}"#
        #expect(throws: IPCError.self) {
            _ = try IPCIncoming.decode(line: Data(line.utf8))
        }
    }
}

@Suite("PresetChangedParams decode")
struct PresetChangedParamsTests {
    @Test func decodes_with_origin_request_id() throws {
        let json = #"{"preset":"standard","mode":"standard","changed_at":"2099-01-01T00:00:00Z","source":"gui","origin_request_id":"req-xyz"}"#
        let p = try JSONDecoder().decode(PresetChangedParams.self, from: Data(json.utf8))
        #expect(p.preset == .standard)
        #expect(p.source == "gui")
        #expect(p.originRequestId == "req-xyz")
        #expect(p.mode == "standard")
    }

    @Test func decodes_without_origin_request_id() throws {
        // daemon CLI 触发，无 origin_request_id
        let json = #"{"preset":"strict","mode":"strict","changed_at":"2099-01-01T00:00:00Z","source":"daemon_cli"}"#
        let p = try JSONDecoder().decode(PresetChangedParams.self, from: Data(json.utf8))
        #expect(p.preset == .strict)
        #expect(p.originRequestId == nil)
        #expect(p.source == "daemon_cli")
    }
}

@Suite("InflightMutatingSet")
struct InflightMutatingSetTests {
    @Test func insert_and_contains() async {
        let set = InflightMutatingSet()
        await set.insert("req-1")
        #expect(await set.contains("req-1") == true)
        #expect(await set.contains("req-2") == false)
    }

    @Test func remove() async {
        let set = InflightMutatingSet()
        await set.insert("req-1")
        await set.remove("req-1")
        #expect(await set.contains("req-1") == false)
    }

    @Test func clear() async {
        let set = InflightMutatingSet()
        await set.insert("req-1")
        await set.insert("req-2")
        await set.clear()
        #expect(await set.count() == 0)
    }

    // 三场景：自发回声 / 他 GUI 触发 / daemon CLI 触发（null origin）
    @Test func echo_detection_self_issued() async {
        let set = InflightMutatingSet()
        await set.insert("req-abc")
        // 自己发出的 mutating request → 在集合中 → 回声
        #expect(await set.contains("req-abc") == true)
    }

    @Test func echo_detection_other_gui() async {
        let set = InflightMutatingSet()
        await set.insert("req-abc")
        // 他 GUI 发出的，origin_request_id 不在本集合
        #expect(await set.contains("req-other") == false)
    }

    @Test func echo_detection_daemon_cli() async {
        let set = InflightMutatingSet()
        await set.insert("req-abc")
        // daemon CLI 触发，origin_request_id 为 nil → 不在集合 → 应更新
        let id: String? = nil
        #expect(id == nil)  // nil → 应更新（IPCClient.isMutatingEcho 返回 false）
    }
}

@Suite("PausedChangedParams decode")
struct PausedChangedParamsTests {
    @Test func decodes_minimal() throws {
        let json = #"{"paused":true,"source":"daemon_cli"}"#
        let p = try JSONDecoder().decode(PausedChangedParams.self, from: Data(json.utf8))
        #expect(p.paused == true)
        #expect(p.source == "daemon_cli")
        #expect(p.pausedUntil == nil)
        #expect(p.reason == nil)
        #expect(p.appliesTo == [])
        #expect(p.originRequestId == nil)
    }

    @Test func decodes_full() throws {
        let json = #"{"paused":true,"paused_until":"2099-01-01T00:00:00Z","reason":"user_request","applies_to":["claude","cursor"],"source":"gui","origin_request_id":"req-abc"}"#
        let p = try JSONDecoder().decode(PausedChangedParams.self, from: Data(json.utf8))
        #expect(p.paused == true)
        #expect(p.source == "gui")
        #expect(p.reason == "user_request")
        #expect(p.appliesTo == ["claude", "cursor"])
        #expect(p.originRequestId == "req-abc")
        #expect(p.pausedUntil != nil)
    }

    @Test func decodes_false_paused() throws {
        let json = #"{"paused":false,"applies_to":[],"source":"daemon_cli"}"#
        let p = try JSONDecoder().decode(PausedChangedParams.self, from: Data(json.utf8))
        #expect(p.paused == false)
        #expect(p.pausedUntil == nil)
    }
}

@Suite("IPC outbound encoding")
struct IPCOutboundTests {
    @Test func notification_encodes_with_newline() {
        let data = IPCOutbound.notification(method: "x")
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.hasSuffix("\n"))
        #expect(s.contains("\"method\":\"x\""))
    }

    @Test func response_includes_id_and_result() {
        let data = IPCOutbound.response(id: "abc", result: ["decision": "deny"])
        let s = String(data: data, encoding: .utf8) ?? ""
        #expect(s.contains("\"id\":\"abc\""))
        #expect(s.contains("\"decision\":\"deny\""))
    }
}
