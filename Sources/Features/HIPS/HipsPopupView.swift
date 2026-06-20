import SwiftUI
import AppKit

public struct HipsPopupView: View {
    let request: HipsRequest
    @ObservedObject var appState: AppState
    /// 5s 内同 rule_id 再次弹窗时为 true，互换主副按钮位置（让肌肉记忆失效，主按钮锁拒绝）
    let swappedLayout: Bool
    let onDecision: (_ decision: Decision, _ remember: Bool, _ hint: String?, _ phase: HipsPhase) -> Void
    let onCloseWithoutDecision: () -> Void
    let isClickSwallowed: () -> Bool

    @State private var rememberChecked: Bool = false
    @State private var contextHint: String = ""
    @State private var lastHovered: Bool = false
    @State private var showCopyJSONAlert: Bool = false

    public init(
        request: HipsRequest,
        appState: AppState,
        swappedLayout: Bool = false,
        onDecision: @escaping (Decision, Bool, String?, HipsPhase) -> Void,
        onCloseWithoutDecision: @escaping () -> Void,
        isClickSwallowed: @escaping () -> Bool
    ) {
        self.request = request
        self.appState = appState
        self.swappedLayout = swappedLayout
        self.onDecision = onDecision
        self.onCloseWithoutDecision = onCloseWithoutDecision
        self.isClickSwallowed = isClickSwallowed
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if request.merged {
                        ForEach(request.issues) { issue in
                            IssueCardView(issue: issue, isUnlocked: appState.isUnlocked)
                        }
                    } else if let context = request.context, let ruleId = request.ruleId {
                        DetailCardView(ruleId: ruleId, context: context, recommendation: request.recommendation, isUnlocked: appState.isUnlocked)
                    }
                    if let rec = request.recommendation {
                        RecommendationBarView(recommendation: rec)
                    }
                }
                .padding(16)
            }
            Divider()
            // SPEC-002 §6 场景 D：失联期间弹窗底部提示，决策将在重连后发送
            if case .disconnected = appState.daemonStatus {
                disconnectedDecisionBanner
                Divider()
            }
            footer.padding(16)
        }
        .frame(minWidth: 540, minHeight: 480)
        .onAppear { rememberChecked = false }
        // SPEC-002 §4.4：复制原始 JSON 二次确认（PRD §5.2.5）
        .alert("原始 JSON 含敏感字段", isPresented: $showCopyJSONAlert) {
            Button("确认复制", role: .destructive) { copyRawJSON() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("原始 JSON 可能含 evidence 等敏感字段，确认复制到剪贴板？\n5 秒后将自动清空剪贴板。")
        }
    }

    /// SPEC-002 §4.4：复制原始请求 JSON 到剪贴板，5 秒后自动清空（受控暴露，需二次确认）。
    private func copyRawJSON() {
        guard let raw = request.rawJSON,
              let str = String(data: raw, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
        // 5 秒后清空剪贴板
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                // 只在剪贴板内容未变时清空（避免清掉用户后续复制的内容）
                if NSPasteboard.general.string(forType: .string) == str {
                    NSPasteboard.general.clearContents()
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            severityIcon
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    SeverityChip(request.severity)
                    DirectionBadge(request.direction)
                    if let rid = request.ruleId {
                        Text(rid).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            CountdownView(remainingSeconds: appState.holdRemainingSeconds, totalSeconds: request.timeoutSeconds)
                .frame(width: 140)
        }
    }

    private var severityIcon: some View {
        let name: String
        let color: Color
        switch request.severity {
        case .critical: name = "exclamationmark.octagon.fill"; color = .red
        case .high: name = "exclamationmark.triangle.fill"; color = .orange
        case .medium: name = "exclamationmark.circle.fill"; color = .yellow
        case .low: name = "info.circle.fill"; color = .secondary
        }
        return Image(systemName: name).foregroundStyle(color)
    }

    // MARK: - Disconnected banner

    /// SPEC-002 §6 场景 D：失联期间的底部提示条（决策将在重连后发送）。
    private var disconnectedDecisionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("与 daemon 失联，你的决策将在连接恢复后发送")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Remember checkbox - 红线：allow_remember=false 时禁止渲染（包括灰显）
            if request.allowRemember {
                Toggle(isOn: $rememberChecked) {
                    Text("记住选择（加入灰名单）")
                        .font(.callout)
                }
                .toggleStyle(.checkbox)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    Text("此规则不允许加入灰名单")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 备注
            TextField("可选备注（≤ 200 字符）", text: $contextHint, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...3)
                .onChange(of: contextHint) { new in
                    // SPEC-005 §1.3: 截断按 Unicode scalar 计数（≤ 200）
                    if new.unicodeScalars.count > 200 {
                        contextHint = String(String.UnicodeScalarView(new.unicodeScalars.prefix(200)))
                    }
                }

            HStack(spacing: 10) {
                // SPEC-002 §4.4：复制原始 JSON 正式按钮（底部最左），二次确认
                if request.rawJSON != nil {
                    Button(action: { showCopyJSONAlert = true }) {
                        Label("复制原始 JSON", systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.bordered)
                    .help("复制原始请求 JSON（含敏感数据，需确认）")
                }
                Spacer()
                // swappedLayout=true 时位置互换：拒绝在左（borderedProminent）+ 允许在右（bordered）
                // 即使 swapped，mainActionLocked / phaseRequiresCmdClick 等约束依然生效
                if swappedLayout {
                    // 互换布局：拒绝首先渲染（视觉靠左），允许靠右（原来主按钮位置）
                    Button(action: { tryDeny() }) { Text("拒绝") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    if !shouldHideAllowAll {
                        Button(action: { tryAllow() }) {
                            Label(allowLabel, systemImage: "checkmark.circle")
                        }
                        .help(phaseRequiresCmdClick ? "按住 ⌘ 点击允许" : "")
                        .buttonStyle(.bordered)
                    }
                } else {
                    if !shouldHideAllowAll {
                        if mainActionLocked || phaseRequiresCmdClick {
                            // 主按钮锁拒绝时，"允许"作为副选；红阶段需 Command-Click
                            Button(action: { tryAllow() }) {
                                Label(allowLabel, systemImage: "checkmark.circle")
                            }
                            .help(phaseRequiresCmdClick ? "按住 ⌘ 点击允许" : "")
                            .buttonStyle(.bordered)
                        } else {
                            Button(action: { tryAllow() }) {
                                Text("允许")
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    if mainActionLocked || swappedLayout {
                        Button(action: { tryDeny() }) { Text("拒绝") }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button(action: { tryDeny() }) { Text("拒绝") }
                            .buttonStyle(.bordered)
                            .keyboardShortcut("d", modifiers: [])
                    }
                }
            }
        }
    }

    private var mainActionLocked: Bool {
        Recommendation.mainActionLocksToDeny(request.recommendation)
    }

    /// 多 issue 含 critical → 隐藏"全部允许"按钮
    private var shouldHideAllowAll: Bool {
        request.merged && request.hasCriticalIssue
    }

    private var phaseRequiresCmdClick: Bool {
        // 当前阶段为 red（剩余 ≤20%）→ 允许按钮需 Command-Click
        let phase = currentPhase
        return phase == .red
    }

    private var currentPhase: HipsPhase {
        let total = request.timeoutSeconds
        let remaining = appState.holdRemainingSeconds
        guard total > 0 else { return .red }
        let r = Double(remaining) / Double(total)
        if r > 0.5 { return .blue }
        if r > 0.2 { return .orange }
        return .red
    }

    private var allowLabel: String {
        phaseRequiresCmdClick ? "按住 ⌘ 点击允许" : "允许"
    }

    private func tryAllow() {
        guard !isClickSwallowed() else { return }
        if phaseRequiresCmdClick {
            // 检查 Command 修饰键
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if !flags.contains(.command) { return }
        }
        onDecision(.allow, request.allowRemember && rememberChecked, contextHint.isEmpty ? nil : contextHint, currentPhase)
    }

    private func tryDeny() {
        guard !isClickSwallowed() else { return }
        onDecision(.deny, false, contextHint.isEmpty ? nil : contextHint, currentPhase)
    }
}
