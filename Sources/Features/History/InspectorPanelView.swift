import SwiftUI

public struct InspectorPanelView: View {
    let row: AuditEventRow
    @ObservedObject var appState: AppState
    @State private var unlocking: Bool = false

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("event #\(row.id)").font(.headline.monospaced())
                    Spacer()
                    SeverityChip(row.severity)
                    DirectionBadge(row.direction)
                }

                fieldRow("rule_id", row.ruleId, mono: true)
                fieldRow("disposition", row.disposition)
                if let uc = row.userChoice { fieldRow("user_choice", uc) }
                fieldRow("created_at", DateFormatter.localizedString(from: row.createdAt, dateStyle: .short, timeStyle: .medium))

                if let fp = row.fingerprint {
                    HStack {
                        Text("fingerprint").font(.caption).foregroundStyle(.secondary)
                        MaskedField(fp, style: .prefix4Suffix4, isUnlocked: contentUnlocked)
                    }
                }
                if let sid = row.sessionId {
                    HStack {
                        Text("session_id").font(.caption).foregroundStyle(.secondary)
                        MaskedField(sid, style: .sessionTrunc, isUnlocked: contentUnlocked)
                    }
                }
                if let pid = row.callerPid {
                    HStack {
                        Text("caller_pid").font(.caption).foregroundStyle(.secondary)
                        // 红线：敏感字段统一走 MaskedField，禁裸 Text；解锁判定与列表同源。
                        MaskedField("\(pid)", style: .clearWhenUnlocked, isUnlocked: contentUnlocked)
                    }
                }

                Divider()

                evidenceMetaSection

                HStack(spacing: 8) {
                    if !appState.isUnlocked {
                        Button {
                            Task { await unlock() }
                        } label: {
                            Label(unlocking ? "解锁中…" : "Touch ID 解锁", systemImage: "touchid")
                        }
                        .disabled(unlocking)
                    } else {
                        Label("已解锁（剩余 \(remainingMinutes) 分钟）", systemImage: "lock.open")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Button("在调试窗口重放") {
                        // 用 ruleId 构建最小可用 evaluate payload（真实 prompt 不存储，ADR-011）
                        let replayPayload = replayPayloadFor(row)
                        WindowManager.shared.replayInDebug(prompt: replayPayload)
                    }
                    .disabled(row.requestId == nil)
                    Button("复制 ID") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString("\(row.id)", forType: .string)
                    }
                }
            }
            .padding(12)
        }
    }

    private var remainingMinutes: Int {
        guard let s = appState.unlockSession else { return 0 }
        return max(0, Int(s.expiresAt.timeIntervalSinceNow / 60))
    }

    private func unlock() async {
        unlocking = true
        defer { unlocking = false }
        _ = await TouchIDService.shared.authenticate(reason: "查看完整 evidence_meta")
    }

    /// 列表与 Inspector 统一的"解锁后是否显示明文"判定（同源，避免明文判定矛盾）。
    private var contentUnlocked: Bool {
        HistoryMaskPolicy.contentUnlocked(appState)
    }

    private var evidenceMetaSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("evidence_meta").font(.caption).foregroundStyle(.secondary)
            if contentUnlocked, let json = row.evidenceMetaJSON {
                // 红线：明文 evidence_meta 仍走 MaskedField（解锁态显示原文），禁裸 Text。
                ScrollView {
                    MaskedField(json, style: .clearWhenUnlocked, isUnlocked: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            } else {
                MaskedField(row.evidenceMetaJSON ?? "", style: .clearWhenUnlocked, isUnlocked: false)
            }
        }
    }

    /// 构建 RuleEvaluation Tab 可用的最小重放 payload。
    /// 真实 prompt 不存储（ADR-011），此处用 rule_id + request_id 构造参考 payload 供调试。
    private func replayPayloadFor(_ row: AuditEventRow) -> String {
        var lines: [String] = [
            "# 重放来源：历史记录 #\(row.id)",
            "# rule_id: \(row.ruleId)",
            "# disposition: \(row.disposition)",
        ]
        if let reqId = row.requestId { lines.append("# request_id: \(reqId)") }
        lines.append("")
        lines.append("# 原始 prompt 不存储（ADR-011）。请在此输入要测试的内容后点「评估」。")
        return lines.joined(separator: "\n")
    }

    private func fieldRow(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top) {
            Text(key).font(.caption).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            if mono { Text(value).font(.system(.callout, design: .monospaced)) } else { Text(value).font(.callout) }
            Spacer()
        }
    }
}
