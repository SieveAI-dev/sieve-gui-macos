import Foundation

public struct Recommendation: Codable, Sendable, Equatable {
    public let decision: Decision
    public let confidence: RecommendationConfidence
    public let reason: String?

    /// 主按钮锁拒绝判定：`recommendation` 缺失或 `confidence != .high` → 锁
    public static func mainActionLocksToDeny(_ rec: Recommendation?) -> Bool {
        guard let rec else { return true }
        return rec.confidence != .high
    }
}
