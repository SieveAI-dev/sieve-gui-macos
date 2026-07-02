import Foundation
import Testing
@testable import SieveGUICore

@Suite("DebugReplayState — replayInDebug 跨 Tab 状态流转")
struct DebugReplayStateTests {
    @Test("初始状态 prefilledPrompt 为 nil")
    func initial_state_is_nil() {
        let state = DebugReplayState()
        #expect(state.prefilledPrompt == nil)
    }

    @Test("setPrefilled 设置后可读取")
    func set_prefilled_readable() {
        var state = DebugReplayState()
        state.setPrefilled("hello world")
        #expect(state.prefilledPrompt == "hello world")
    }

    @Test("consumePrefilled 返回值并置 nil（one-shot 语义）")
    func consume_clears_after_read() {
        var state = DebugReplayState()
        state.setPrefilled("test payload")
        let consumed = state.consumePrefilled()
        #expect(consumed == "test payload")
        // 消费后 prefilledPrompt 应为 nil
        #expect(state.prefilledPrompt == nil)
    }

    @Test("consumePrefilled 在 nil 状态下返回 nil")
    func consume_nil_when_empty() {
        var state = DebugReplayState()
        let result = state.consumePrefilled()
        #expect(result == nil)
        #expect(state.prefilledPrompt == nil)
    }

    @Test("多次 setPrefilled 后最新值生效")
    func last_set_wins() {
        var state = DebugReplayState()
        state.setPrefilled("first")
        state.setPrefilled("second")
        #expect(state.prefilledPrompt == "second")
        let consumed = state.consumePrefilled()
        #expect(consumed == "second")
    }
}
