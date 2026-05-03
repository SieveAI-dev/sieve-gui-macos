import Foundation

/// DebugReplayStore 的状态核心（值类型，可单元测试）。
/// DebugReplayStore（App 层 ObservableObject）持有此状态，WindowManager.replayInDebug 写入，
/// RuleEvaluationTab.onAppear 通过 consumePrefilled() 读取并消费（one-shot 语义）。
public struct DebugReplayState: Sendable, Equatable {
    /// 待填入 RuleEvaluation textarea 的 payload。nil = 无待消费重放。
    public private(set) var prefilledPrompt: String?

    public init(prefilledPrompt: String? = nil) {
        self.prefilledPrompt = prefilledPrompt
    }

    /// 设置 payload（由 WindowManager.replayInDebug 调用）。
    public mutating func setPrefilled(_ prompt: String) {
        prefilledPrompt = prompt
    }

    /// 消费 payload：返回值后置 nil（one-shot）。
    public mutating func consumePrefilled() -> String? {
        defer { prefilledPrompt = nil }
        return prefilledPrompt
    }
}
