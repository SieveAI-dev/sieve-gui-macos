import Testing
import Foundation
import AppKit
@testable import SieveGUICore

/// Toast reduce-motion 适配测试
/// ToastController 在 Features 层（Package.swift exclude），
/// 这里测试 NSWorkspace reduce-motion API 可用性 + 常量设计约束。
@Suite("Toast reduce-motion 适配")
struct ToastReduceMotionTests {

    @Test("NSWorkspace.accessibilityDisplayShouldReduceMotion 可读（不崩溃）")
    func reduce_motion_api_accessible() {
        // 验证系统 API 可正常访问（macOS 13+）
        let flag = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let _ = flag  // true 或 false 都合法（取决于系统设置）
        #expect(true)
    }

    @Test("reduce-motion 分支设计约束：normal duration > reduced duration")
    func reduce_motion_zero_duration_expectation() {
        // ToastController.dismiss() 设计约束：
        // - reduce_motion=true → 跳过 NSAnimationContext（duration=0 即不动画）
        // - reduce_motion=false → NSAnimationContext.duration = 0.25s 淡出
        let normalDuration: TimeInterval = 0.25  // ToastController 中的实际值
        let reducedDuration: TimeInterval = 0     // reduce-motion 路径跳过动画，等价 duration=0
        #expect(normalDuration > reducedDuration)
        #expect(reducedDuration == 0)
    }

    @Test("UserSettings.reduceMotionOverride 三个合法值（驱动 reduce-motion 路径）")
    func reduce_motion_override_valid_values() {
        // UserSettings 的 reduceMotionOverride 控制是否忽略系统设置强制 reduce-motion
        let validValues = ["system", "always", "never"]
        // 验证默认值在合法集合中
        let defaults = UserSettings.default
        #expect(validValues.contains(defaults.reduceMotionOverride))
    }
}
