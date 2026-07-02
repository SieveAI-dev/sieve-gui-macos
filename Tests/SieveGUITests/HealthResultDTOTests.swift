import Foundation
import Testing
@testable import SieveGUICore

@Suite("sieve.health 解码（SPEC-005 §9.5，listeners[]）")
struct HealthResultDTOTests {
    // MARK: - 完整 SPEC-005 §9.5 响应

    @Test("完整字段（新 daemon）：listen + listeners 同时存在，listeners 权威")
    func decode_full_with_listeners() throws {
        let json = #"""
        {
          "daemon_version": "0.7.2",
          "protocol_version": "v2",
          "started_at": "2026-05-02T11:21:30.001Z",
          "uptime_seconds": 14523,
          "preset": { "mode": "standard", "overrides": {} },
          "paused": false,
          "paused_until": null,
          "listen": { "addr": "127.0.0.1", "port": 11453 },
          "listeners": [
            { "addr": "127.0.0.1", "port": 11453, "provider_id": "anthropic", "protocol": "anthropic" },
            { "addr": "127.0.0.1", "port": 11454, "provider_id": "deepseek",  "protocol": "anthropic" },
            { "addr": "127.0.0.1", "port": 11455, "provider_id": "openai",    "protocol": "openai"   }
          ],
          "audit_db": {
            "path": "/Users/foo/.sieve/audit.db",
            "size_bytes": 2048576,
            "schema_version": 2,
            "events_total": 12453,
            "events_today": 142
          },
          "rules": {
            "system_count": 47,
            "user_count": 3,
            "last_reload": "2026-05-02T11:21:31.234Z"
          },
          "graylist": { "active_count": 5 },
          "ipc": { "connected_clients": 1, "total_decisions_inflight": 0 }
        }
        """#.data(using: .utf8)!

        let dto = try JSONDecoder().decode(HealthResultDTO.self, from: json)

        #expect(dto.daemonVersion == "0.7.2")
        #expect(dto.protocolVersion == "v2")
        #expect(dto.uptimeSeconds == 14523)
        #expect(dto.preset.mode == .standard)
        #expect(dto.preset.overrides.isEmpty)
        #expect(dto.paused == false)
        #expect(dto.pausedUntil == nil)

        // listen 兼容字段仍可读
        #expect(dto.listen.addr == "127.0.0.1")
        #expect(dto.listen.port == 11453)

        // listeners 数组完整
        #expect(dto.listeners.count == 3)
        #expect(dto.listeners[0].providerId == "anthropic")
        #expect(dto.listeners[0].protocol == "anthropic")
        #expect(dto.listeners[1].port == 11454)
        #expect(dto.listeners[1].providerId == "deepseek")
        #expect(dto.listeners[2].providerId == "openai")
        #expect(dto.listeners[2].protocol == "openai")

        // effectiveListeners 优先用 listeners[]
        #expect(dto.effectiveListeners.count == 3)
        #expect(dto.effectiveListeners[0].providerId == "anthropic")

        // 子结构
        #expect(dto.auditDb.schemaVersion == 2)
        #expect(dto.auditDb.eventsTotal == 12453)
        #expect(dto.auditDb.sizeBytes == 2_048_576)
        #expect(dto.rules.systemCount == 47)
        #expect(dto.rules.userCount == 3)
        #expect(dto.rules.lastReload != nil)
        #expect(dto.graylist.activeCount == 5)
        #expect(dto.ipc.connectedClients == 1)
        #expect(dto.ipc.totalDecisionsInflight == 0)
    }

    @Test("Daemon Settings：IPC 失联时只禁用 reload，health 和 doctor 仍可尝试")
    func daemon_settings_actions_when_disconnected() {
        let availability = DaemonSettingsActionAvailability.resolve(
            daemonStatus: .disconnected(reason: .connectionRefused)
        )

        #expect(availability.canReloadConfig == false)
        #expect(availability.canRunHealthCheck == true)
        #expect(availability.canRunDoctor == true)
    }

    @Test("Daemon Settings：连接态允许 reload、health 和 doctor")
    func daemon_settings_actions_when_connected() {
        let availability = DaemonSettingsActionAvailability.resolve(daemonStatus: .normal)

        #expect(availability.canReloadConfig == true)
        #expect(availability.canRunHealthCheck == true)
        #expect(availability.canRunDoctor == true)
    }

    // MARK: - 旧 daemon 兼容路径

    @Test("旧 daemon：仅 listen 字段，无 listeners → effectiveListeners 退化")
    func decode_legacy_without_listeners() throws {
        let json = #"""
        {
          "daemon_version": "0.6.9",
          "protocol_version": "v2",
          "started_at": "2026-05-02T11:21:30.001Z",
          "uptime_seconds": 100,
          "preset": { "mode": "standard", "overrides": {} },
          "paused": false,
          "paused_until": null,
          "listen": { "addr": "127.0.0.1", "port": 11453 },
          "audit_db": {
            "path": "/Users/foo/.sieve/audit.db",
            "size_bytes": 1024,
            "schema_version": 2,
            "events_total": 0,
            "events_today": 0
          },
          "rules": { "system_count": 47, "user_count": 0, "last_reload": null },
          "graylist": { "active_count": 0 },
          "ipc": { "connected_clients": 1, "total_decisions_inflight": 0 }
        }
        """#.data(using: .utf8)!

        let dto = try JSONDecoder().decode(HealthResultDTO.self, from: json)

        // 旧 daemon 不发 listeners[]，decodeIfPresent 兜底为空数组
        #expect(dto.listeners.isEmpty)

        // effectiveListeners 应回落到 listen 派生的单元素数组
        let eff = dto.effectiveListeners
        #expect(eff.count == 1)
        #expect(eff[0].addr == "127.0.0.1")
        #expect(eff[0].port == 11453)
        #expect(eff[0].providerId == "(legacy)")
        #expect(eff[0].protocol == "(legacy)")

        // last_reload null 解析为 nil
        #expect(dto.rules.lastReload == nil)
    }

    // MARK: - 暂停态

    @Test("暂停态：paused=true + paused_until 有值")
    func decode_paused_with_until() throws {
        let json = #"""
        {
          "daemon_version": "0.7.2",
          "protocol_version": "v2",
          "started_at": "2026-05-02T11:21:30.001Z",
          "uptime_seconds": 100,
          "preset": { "mode": "strict", "overrides": {} },
          "paused": true,
          "paused_until": "2026-05-02T13:00:00.000Z",
          "listen": { "addr": "127.0.0.1", "port": 11453 },
          "listeners": [
            { "addr": "127.0.0.1", "port": 11453, "provider_id": "anthropic", "protocol": "anthropic" }
          ],
          "audit_db": {
            "path": "/Users/foo/.sieve/audit.db",
            "size_bytes": 1024, "schema_version": 2,
            "events_total": 0, "events_today": 0
          },
          "rules": { "system_count": 47, "user_count": 0, "last_reload": null },
          "graylist": { "active_count": 0 },
          "ipc": { "connected_clients": 1, "total_decisions_inflight": 0 }
        }
        """#.data(using: .utf8)!

        let dto = try JSONDecoder().decode(HealthResultDTO.self, from: json)
        #expect(dto.paused == true)
        #expect(dto.pausedUntil != nil)
        #expect(dto.preset.mode == .strict)
    }

    // MARK: - Custom preset overrides

    @Test("custom preset 含 overrides")
    func decode_custom_preset_with_overrides() throws {
        let json = #"""
        {
          "daemon_version": "0.7.2",
          "protocol_version": "v2",
          "started_at": "2026-05-02T11:21:30.001Z",
          "uptime_seconds": 100,
          "preset": {
            "mode": "custom",
            "overrides": {
              "OUT-08": { "timeout_seconds": 90, "default_on_timeout": "allow" }
            }
          },
          "paused": false, "paused_until": null,
          "listen": { "addr": "127.0.0.1", "port": 11453 },
          "listeners": [
            { "addr": "127.0.0.1", "port": 11453, "provider_id": "anthropic", "protocol": "anthropic" }
          ],
          "audit_db": {
            "path": "/Users/foo/.sieve/audit.db",
            "size_bytes": 1024, "schema_version": 2,
            "events_total": 0, "events_today": 0
          },
          "rules": { "system_count": 47, "user_count": 0, "last_reload": null },
          "graylist": { "active_count": 0 },
          "ipc": { "connected_clients": 1, "total_decisions_inflight": 0 }
        }
        """#.data(using: .utf8)!

        let dto = try JSONDecoder().decode(HealthResultDTO.self, from: json)
        #expect(dto.preset.mode == .custom)
        #expect(dto.preset.overrides.count == 1)
        let ov = try #require(dto.preset.overrides["OUT-08"])
        #expect(ov.timeoutSeconds == 90)
        #expect(ov.defaultOnTimeout == .allow)
    }

    // MARK: - ListenerSnapshot 字段

    @Test("ListenerSnapshot.id 派生为 addr:port，可用于 ForEach")
    func listener_snapshot_id_derivation() throws {
        let json = #"""
        {
          "daemon_version": "0.7.2", "protocol_version": "v2",
          "started_at": "2026-05-02T11:21:30.001Z", "uptime_seconds": 1,
          "preset": { "mode": "standard", "overrides": {} },
          "paused": false, "paused_until": null,
          "listen": { "addr": "127.0.0.1", "port": 11453 },
          "listeners": [
            { "addr": "127.0.0.1", "port": 11454, "provider_id": "x", "protocol": "anthropic" }
          ],
          "audit_db": { "path": "/", "size_bytes": 0, "schema_version": 2, "events_total": 0, "events_today": 0 },
          "rules": { "system_count": 1, "user_count": 0, "last_reload": null },
          "graylist": { "active_count": 0 },
          "ipc": { "connected_clients": 1, "total_decisions_inflight": 0 }
        }
        """#.data(using: .utf8)!

        let dto = try JSONDecoder().decode(HealthResultDTO.self, from: json)
        #expect(dto.listeners[0].id == "127.0.0.1:11454")
    }

    // MARK: - 必填字段缺失

    @Test("缺少 daemon_version 必填字段 → decode 失败")
    func decode_missing_required_field() throws {
        let json = #"""
        {
          "protocol_version": "v2",
          "started_at": "2026-05-02T11:21:30.001Z",
          "uptime_seconds": 1,
          "preset": { "mode": "standard", "overrides": {} },
          "paused": false, "paused_until": null,
          "listen": { "addr": "127.0.0.1", "port": 11453 },
          "audit_db": { "path": "/", "size_bytes": 0, "schema_version": 2, "events_total": 0, "events_today": 0 },
          "rules": { "system_count": 1, "user_count": 0, "last_reload": null },
          "graylist": { "active_count": 0 },
          "ipc": { "connected_clients": 1, "total_decisions_inflight": 0 }
        }
        """#.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(HealthResultDTO.self, from: json)
        }
    }

    // MARK: - started_at 非法格式

    @Test("started_at 不是合法 ISO8601 → decode 失败")
    func decode_invalid_started_at() throws {
        let json = #"""
        {
          "daemon_version": "0.7.2", "protocol_version": "v2",
          "started_at": "not-a-date", "uptime_seconds": 1,
          "preset": { "mode": "standard", "overrides": {} },
          "paused": false, "paused_until": null,
          "listen": { "addr": "127.0.0.1", "port": 11453 },
          "audit_db": { "path": "/", "size_bytes": 0, "schema_version": 2, "events_total": 0, "events_today": 0 },
          "rules": { "system_count": 1, "user_count": 0, "last_reload": null },
          "graylist": { "active_count": 0 },
          "ipc": { "connected_clients": 1, "total_decisions_inflight": 0 }
        }
        """#.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(HealthResultDTO.self, from: json)
        }
    }
}
