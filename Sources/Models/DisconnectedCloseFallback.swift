import Foundation

/// 失联期间用户关窗的兜底决策（P0-4）。
///
/// 失联时 `-32100`（user_canceled_via_window_close）无连接可发、帧被静默丢弃，
/// daemon 只能干等 hold 超时。取消与拒绝对 daemon 的安全效果一致，故失联关窗
/// 按 deny 入失联缓存，重连后随缓存重发（daemon 按 request_id 去重）；
/// 审计侧记录为用户 deny 而非 timeout，比静默丢弃更接近用户意图。
public enum DisconnectedCloseFallback {
    public static func payload(for req: HipsRequest, phase: HipsPhase) -> PendingDecisionPayload {
        if req.merged {
            let perIssue = MergedDecisionBuilder.perIssues(for: req.issues, action: .denyAll)
            return .merged(MergedDecisionResponse(id: req.id, perIssue: perIssue, byUser: true))
        }
        let response = DecisionResponse(
            id: req.id,
            decision: .deny,
            remember: false,
            contextHint: nil,
            byUser: true,
            uiPhaseWhenClicked: phase
        )
        return .single(response, allowRemember: req.allowRemember)
    }
}
