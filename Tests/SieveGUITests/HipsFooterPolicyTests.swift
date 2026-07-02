import Foundation
import Testing
@testable import SieveGUICore

/// P0-2/P0-3：HIPS footer 键盘归属矩阵。
/// HipsPopupView 在 Features 层（swift test 编不到），此处锚定 View 消费的策略函数：
/// Return 恒在拒绝侧、允许类按钮零 keyboardShortcut、red 阶段键盘无法触发允许。
@Suite("HipsFooterPolicy：Return 恒绑拒绝，允许类零快捷键")
struct HipsFooterPolicyTests {
    /// 全状态空间：{locked} × {red} × {swapped} × {merged, canAllowAll}
    private var allStates: [HipsFooterPolicy.FooterState] {
        var states: [HipsFooterPolicy.FooterState] = []
        for locked in [false, true] {
            for red in [false, true] {
                for swapped in [false, true] {
                    for (merged, canAllowAll) in [(false, false), (true, false), (true, true)] {
                        states.append(.init(
                            mainActionLocked: locked,
                            phaseRequiresCmdClick: red,
                            swappedLayout: swapped,
                            merged: merged,
                            canAllowAll: canAllowAll
                        ))
                    }
                }
            }
        }
        return states
    }

    @Test("矩阵：任何组合下 Return（defaultAction）归属恒为拒绝侧")
    func return_key_always_binds_to_deny() {
        for state in allStates {
            #expect(HipsFooterPolicy.returnKeyOwner(state) == .deny, "state=\(state)")
        }
    }

    @Test("矩阵：任何组合下允许类按钮不得挂任何 keyboardShortcut")
    func allow_buttons_never_have_keyboard_shortcut() {
        for state in allStates {
            #expect(!HipsFooterPolicy.allowMayHaveKeyboardShortcut(state), "state=\(state)")
        }
    }

    @Test("视觉主选在允许侧：仅『高置信推荐 + 非 red + 非换位 + 非 merged』")
    func allow_prominence_only_in_safe_state() {
        #expect(HipsFooterPolicy.allowIsProminent(
            .init(mainActionLocked: false, phaseRequiresCmdClick: false, swappedLayout: false)
        ))
        // 任一危险信号出现 → 视觉主选回到拒绝侧
        #expect(!HipsFooterPolicy.allowIsProminent(
            .init(mainActionLocked: true, phaseRequiresCmdClick: false, swappedLayout: false)
        ))
        #expect(!HipsFooterPolicy.allowIsProminent(
            .init(mainActionLocked: false, phaseRequiresCmdClick: true, swappedLayout: false)
        ))
        #expect(!HipsFooterPolicy.allowIsProminent(
            .init(mainActionLocked: false, phaseRequiresCmdClick: false, swappedLayout: true)
        ))
        #expect(!HipsFooterPolicy.allowIsProminent(
            .init(mainActionLocked: false, phaseRequiresCmdClick: false, swappedLayout: false, merged: true)
        ))
    }
}

/// P0-3：red 阶段 ⌘+Click 门——键盘路径（含任何快捷键触发）一律不放行。
@Suite("CmdClickGate：red 阶段允许必须是带 ⌘ 的鼠标点击")
struct CmdClickGateTests {
    @Test("red + 键盘触发（无论是否带修饰键）→ 不放行")
    func red_phase_keyboard_never_allows() {
        #expect(!CmdClickGate.permitsAllow(
            phaseRequiresCmdClick: true, eventIsMouseClick: false, hasCommandModifier: false
        ))
        #expect(!CmdClickGate.permitsAllow(
            phaseRequiresCmdClick: true, eventIsMouseClick: false, hasCommandModifier: true
        ))
    }

    @Test("red + 鼠标点击无 ⌘ → 不放行；带 ⌘ → 放行")
    func red_phase_mouse_requires_command() {
        #expect(!CmdClickGate.permitsAllow(
            phaseRequiresCmdClick: true, eventIsMouseClick: true, hasCommandModifier: false
        ))
        #expect(CmdClickGate.permitsAllow(
            phaseRequiresCmdClick: true, eventIsMouseClick: true, hasCommandModifier: true
        ))
    }

    @Test("非 red 阶段 → 门不生效，正常放行")
    func non_red_phase_passes_through() {
        #expect(CmdClickGate.permitsAllow(
            phaseRequiresCmdClick: false, eventIsMouseClick: false, hasCommandModifier: false
        ))
    }
}
