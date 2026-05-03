import Foundation
import Combine

/// History → Debug Tab 重放状态桥。
/// WindowManager.replayInDebug(prompt:) 写入；RuleEvaluationTab.onAppear 读取并清空。
/// 核心状态逻辑由 DebugReplayState（Models 层值类型）实现，此处做 ObservableObject 包装。
@MainActor
public final class DebugReplayStore: ObservableObject {
    public static let shared = DebugReplayStore()

    /// 待填入 RuleEvaluationTab 的 payload（nil = 无待消费重放）。
    /// @Published 保证 onChange(of:) 可以检测到变化。
    @Published public private(set) var prefilledPrompt: String? = nil

    public func setPrefilled(_ prompt: String) {
        prefilledPrompt = prompt
    }

    public func consumePrefilled() -> String? {
        defer { prefilledPrompt = nil }
        return prefilledPrompt
    }
}
