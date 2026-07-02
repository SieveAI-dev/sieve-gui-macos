import Testing
@testable import SieveGUICore

@Suite("DetectionPreset selection guard")
struct DetectionPresetSelectionStateTests {
    @Test("点击当前 preset 不进入确认状态")
    func selecting_current_preset_does_not_prompt() {
        var state = DetectionPresetSelectionState(current: .standard)
        let shouldPrompt = state.select(.standard)
        #expect(!shouldPrompt)
        #expect(state.pending == nil)
    }

    @Test("点击不同 preset 才进入确认状态")
    func selecting_different_preset_prompts() {
        var state = DetectionPresetSelectionState(current: .standard)
        let shouldPrompt = state.select(.strict)
        #expect(shouldPrompt)
        #expect(state.pending == .strict)
    }

    @Test("取消会清除待切换 preset")
    func cancel_clears_pending() {
        var state = DetectionPresetSelectionState(current: .standard)
        _ = state.select(.custom)
        state.cancel()
        #expect(state.pending == nil)
        #expect(state.current == .standard)
    }

    @Test("确认后 current 更新且 pending 清空")
    func apply_pending_updates_current() {
        var state = DetectionPresetSelectionState(current: .standard)
        _ = state.select(.relaxed)
        let applied = state.applyPending()
        #expect(applied == .relaxed)
        #expect(state.current == .relaxed)
        #expect(state.pending == nil)
    }
}
