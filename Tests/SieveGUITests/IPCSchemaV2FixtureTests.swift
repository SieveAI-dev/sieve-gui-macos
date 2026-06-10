import Foundation
import Testing

@testable import SieveGUICore

/// SPEC-005 §14.2：消费 daemon 权威 fixture 副本（`Tests/SieveGUITests/Fixtures/v2/`），
/// 而非内联手写 JSON——保证 GUI 解码与 daemon 序列化输出对齐，杜绝跨仓 schema 漂移。
///
/// fixture 由 daemon 仓 `crates/sieve-ipc/tests/fixtures/v2/sieve.health/` 拷贝而来
/// （pin 见 `docs/external/upstream-references.md`）。daemon 侧 `schema_v2_fixtures.rs`
/// 的双向稳定测试保证这些 fixture 等于 daemon 真实 wire 输出；本测试保证 GUI 端
/// `HealthResultDTO` 能正确消费同一份权威 fixture。两侧共用同一 JSON = 无漂移空间。
///
/// 与 `HealthResultDTOTests`（内联 JSON 覆盖解码逻辑分支）互补：本测试专测「与 daemon
/// 权威产物的一致性」，前者测「解码逻辑的完整性」。
@Suite("SPEC-005 §14.2 daemon fixture 副本一致性")
struct IPCSchemaV2FixtureTests {

    /// 读取 fixture bundle 中的 JSON-RPC response，提取并返回其 `result` 字段的原始 Data。
    ///
    /// daemon fixture 是完整 envelope（`{jsonrpc, result, id}`）；`HealthResultDTO`
    /// 解码的是 `result` 内容，故先剥 envelope 再交给 `JSONDecoder`。
    private func loadHealthResult(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/v2/sieve.health"
            ),
            "fixture \(name).json 缺失——应从 daemon 仓拷贝到 Tests/SieveGUITests/Fixtures/v2/sieve.health/"
        )
        let data = try Data(contentsOf: url)
        let obj = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "fixture \(name).json 不是 JSON object"
        )
        let result = try #require(obj["result"], "fixture \(name).json 缺 result 字段")
        return try JSONSerialization.data(withJSONObject: result)
    }

    @Test("response.full：daemon 权威 fixture 的 listeners[] 完整解码")
    func decode_full_fixture() throws {
        let dto = try JSONDecoder().decode(HealthResultDTO.self, from: loadHealthResult("response.full"))

        // ADR-026 multi-listener：full fixture 列 2 个 listener，含 provider_id + protocol。
        #expect(dto.listeners.count == 2)
        #expect(dto.listeners[0].providerId == "anthropic")
        #expect(dto.listeners[0].protocol == "anthropic")
        #expect(dto.listeners[1].port == 11454)
        #expect(dto.listeners[1].providerId == "deepseek")
        // daemon 侧 Protocol::Auto（簇 A 修复）在 wire 上序列化为 "auto"。
        #expect(dto.listeners[1].protocol == "auto")

        // effectiveListeners 优先用 listeners[]。
        #expect(dto.effectiveListeners.count == 2)
        // 向后兼容 listen 单字段仍可读。
        #expect(dto.listen.port == 11453)
        #expect(dto.paused == true)
    }

    @Test("response.minimal：省略 listeners → 空数组 + effectiveListeners 回落 listen")
    func decode_minimal_fixture() throws {
        let dto = try JSONDecoder().decode(HealthResultDTO.self, from: loadHealthResult("response.minimal"))

        #expect(dto.listeners.isEmpty)
        // 无 listeners[] 时回落到 listen 派生的单元素数组（与旧 daemon 兼容）。
        #expect(dto.effectiveListeners.count == 1)
        #expect(dto.effectiveListeners[0].port == 11453)
        #expect(dto.paused == false)
    }

    @Test("response.null_optional：listeners 显式空数组 + 可选字段 null")
    func decode_null_optional_fixture() throws {
        let dto = try JSONDecoder().decode(
            HealthResultDTO.self, from: loadHealthResult("response.null_optional"))

        #expect(dto.listeners.isEmpty)
        #expect(dto.pausedUntil == nil)
        #expect(dto.rules.lastReload == nil)
    }
}
