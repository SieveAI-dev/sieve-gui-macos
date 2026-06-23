import Testing
import Foundation
@testable import SieveGUICore

/// UserSettings.reduceMotionEnabled(systemReduceMotion:) 纯函数解析测试。
/// 验证 override（system/always/never）如何与系统 flag 合成最终 reduce-motion 生效值。
@Suite("reduceMotionEnabled 解析")
struct ReduceMotionResolveTests {

    private func settings(_ override: String) -> UserSettings {
        var s = UserSettings.default
        s.reduceMotionOverride = override
        return s
    }

    @Test("system → 透传系统 flag（true）")
    func system_passthrough_true() {
        #expect(settings("system").reduceMotionEnabled(systemReduceMotion: true) == true)
    }

    @Test("system → 透传系统 flag（false）")
    func system_passthrough_false() {
        #expect(settings("system").reduceMotionEnabled(systemReduceMotion: false) == false)
    }

    @Test("always → 恒 true（忽略系统 flag）")
    func always_forces_true() {
        #expect(settings("always").reduceMotionEnabled(systemReduceMotion: false) == true)
        #expect(settings("always").reduceMotionEnabled(systemReduceMotion: true) == true)
    }

    @Test("never → 恒 false（忽略系统 flag）")
    func never_forces_false() {
        #expect(settings("never").reduceMotionEnabled(systemReduceMotion: true) == false)
        #expect(settings("never").reduceMotionEnabled(systemReduceMotion: false) == false)
    }
}
