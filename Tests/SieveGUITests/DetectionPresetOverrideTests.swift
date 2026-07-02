import Foundation
import Testing
@testable import SieveGUICore

@Suite("DetectionPreset Custom 模式内联编辑 + sieve.set_preset_overrides")
struct DetectionPresetOverrideTests {
    // MARK: - RuleOverride clamp

    @Test("timeout_seconds 低于 30 被 clamp 到 30")
    func clamp_timeout_min() {
        let o = RuleOverride(ruleId: "OUT-01", timeoutSeconds: 10, defaultOnTimeout: "block")
        #expect(o.timeoutSeconds == 30)
    }

    @Test("timeout_seconds 高于 600 被 clamp 到 600")
    func clamp_timeout_max() {
        let o = RuleOverride(ruleId: "OUT-01", timeoutSeconds: 999, defaultOnTimeout: "allow")
        #expect(o.timeoutSeconds == 600)
    }

    @Test("timeout_seconds 在 [30, 600] 范围内不变")
    func valid_timeout_unchanged() {
        let o = RuleOverride(ruleId: "OUT-02", timeoutSeconds: 120, defaultOnTimeout: "allow")
        #expect(o.timeoutSeconds == 120)
    }

    @Test("default_on_timeout 只允许 block / allow")
    func valid_dot_values() {
        #expect(RuleOverride.validDefaults == ["block", "allow"])
        #expect(!RuleOverride.validDefaults.contains("redact"))
        let allow = RuleOverride(ruleId: "OUT-01", timeoutSeconds: 60, defaultOnTimeout: "allow")
        let block = RuleOverride(ruleId: "OUT-01", timeoutSeconds: 60, defaultOnTimeout: "block")
        #expect(allow.defaultOnTimeout == "allow")
        #expect(block.defaultOnTimeout == "block")
    }

    // MARK: - SetPresetOverridesParams 编码

    @Test("SetPresetOverridesParams 编码为正确 snake_case JSON")
    func encodes_to_snake_case() throws {
        let params = SetPresetOverridesParams(ruleId: "OUT-01", timeoutSeconds: 60, defaultOnTimeout: "allow")
        let data = try JSONEncoder().encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["rule_id"] as? String == "OUT-01")
        #expect(json?["timeout_seconds"] as? Int == 60)
        #expect(json?["default_on_timeout"] as? String == "allow")
        // 驼峰字段不应出现
        #expect(json?["ruleId"] == nil)
        #expect(json?["timeoutSeconds"] == nil)
        #expect(json?["defaultOnTimeout"] == nil)
    }
}
