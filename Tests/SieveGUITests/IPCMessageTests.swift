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
