import Foundation

/// History 列表（Detail 列）与 Inspector 共享的脱敏判定单一真实源。
///
/// 死链修复前两处规则不一致：列表用 `isUnlocked && !historyMaskByDefault`，
/// Inspector 的 evidence_meta / caller_pid 只看 `isUnlocked` → 解锁后明文判定矛盾。
/// 统一为：仅当「已 Touch ID 解锁」且「未开启历史默认脱敏」时才显示明文。
public enum HistoryMaskPolicy {
    /// 解锁态内容是否显示明文（evidence_meta / caller_pid / Detail 列）。
    @MainActor
    public static func contentUnlocked(_ appState: AppState) -> Bool {
        appState.isUnlocked && !appState.settings.historyMaskByDefault
    }
}
