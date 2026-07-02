import AppKit
import SwiftUI

public struct HipsPopupView: View {
    let request: HipsRequest
    @ObservedObject var appState: AppState
    /// 5s 内同 rule_id 再次弹窗时为 true，互换主副按钮位置（让肌肉记忆失效，主按钮锁拒绝）
    let swappedLayout: Bool
    let onDecision: (_ decision: Decision, _ remember: Bool, _ hint: String?, _ phase: HipsPhase) -> Void
    let onCloseWithoutDecision: () -> Void
    let isClickSwallowed: () -> Bool
    /// 多 issue 合并模式的整体决策（拒绝全部 / 仅允许非 Critical / 全部允许）
    let onMergedDecision: (MergedAction) -> Void
    /// SPEC-002 §4.4：字段解锁的「人在场」认证（不建会话）。默认 fail-closed 恒拒。
    let requestFieldUnlock: () async -> Bool

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
        isClickSwallowed: @escaping () -> Bool,
        onMergedDecision: @escaping (MergedAction) -> Void = { _ in },
        requestFieldUnlock: @escaping () async -> Bool = { false }
    ) {
        self.request = request
        self.appState = appState
        self.swappedLayout = swappedLayout
        self.onDecision = onDecision
        self.onCloseWithoutDecision = onCloseWithoutDecision
        self.isClickSwallowed = isClickSwallowed
        self.onMergedDecision = onMergedDecision
        self.requestFieldUnlock = requestFieldUnlock
    }

    /// SPEC-002 §4.4/§5.2：解锁态 owner 在 AppState（与 History `unlockSession` 并列隔离），
    /// 而非 View @State——使锁屏/会话过期/关窗/新弹窗都能实时驱动其失效。绑定 request_id：
    /// 只有「当前请求 == 解锁时的请求」才显示明文。
    private var fieldsUnlocked: Bool {
        appState.hipsFieldUnlock.isUnlocked(for: request.id)
    }

    /// 当前模板是否存在可解锁的脱敏字段（secret_outbound/markdown_exfil 不推全文，无解锁入口）。
    private var hasUnlockableFields: Bool {
        if request.merged { return !request.issues.isEmpty }
        switch request.context {
        case .addressCompare, .signingToolUse, .generic: return true
        case .markdownExfil, .secretOutbound, .none: return false
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if request.merged {
                        ForEach(request.issues) { issue in
                            IssueCardView(issue: issue, isUnlocked: fieldsUnlocked)
                        }
                    } else if let context = request.context, let ruleId = request.ruleId {
                        DetailCardView(
                            ruleId: ruleId,
                            context: context,
                            recommendation: request.recommendation,
                            isUnlocked: fieldsUnlocked
                        )
                    }
                    // SPEC-002 §4.4：字段解锁与 History 会话隔离——每个弹窗独立认证，
                    // 认证不建会话；失败/取消保持脱敏、不自动重弹（可手动再点）。
                    if hasUnlockableFields {
                        fieldUnlockControl
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
        // SPEC-002 §4.4：复制原始 JSON 二次确认
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

    // MARK: - Field unlock（SPEC-002 §4.4）

    @ViewBuilder
    private var fieldUnlockControl: some View {
        if fieldsUnlocked {
            HStack(spacing: 6) {
                Image(systemName: "lock.open").foregroundStyle(.secondary)
                Text("敏感字段已解锁（仅本弹窗有效）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button(action: { tryFieldUnlock() }) {
                Label("显示完整字段（Touch ID）", systemImage: "lock.fill")
            }
            .buttonStyle(.bordered)
            .help("解锁仅对当前弹窗有效，关闭即失效；与历史窗口的解锁互不相干")
        }
    }

    private func tryFieldUnlock() {
        let requestId = request.id
        Task { @MainActor in
            if await requestFieldUnlock() {
                // 认证成功 → 上收到 AppState 的独立解锁态（不建 History 会话，隔离方向 2）。
                appState.unlockHipsField(requestId: requestId)
            }
            // 失败/取消：保持脱敏视图，不自动再次弹认证
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
                if rememberChecked {
                    TextField("可选备注（≤ 200 字符）", text: $contextHint, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2 ... 3)
                        .onChange(of: contextHint) { new in
                            // SPEC-005 §1.3: 截断按 Unicode scalar 计数（≤ 200）
                            if new.unicodeScalars.count > 200 {
                                contextHint = String(String.UnicodeScalarView(new.unicodeScalars.prefix(200)))
                            }
                        }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary)
                    Text("此规则不允许加入灰名单")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                // P0-2/P0-3 红线（HipsFooterPolicy 矩阵测试锚定）：Return（.defaultAction）在
                // 任何组合下只绑定拒绝侧；允许类按钮永不挂 keyboardShortcut——键盘无法触发允许。
                // swappedLayout=true 时位置互换：拒绝在左（borderedProminent）+ 允许在右（bordered）
                // 即使 swapped，mainActionLocked / phaseRequiresCmdClick 等约束依然生效
                if request.merged {
                    mergedActionButtons
                } else if swappedLayout {
                    // 互换布局：拒绝首先渲染（视觉靠左），允许靠右（原来主按钮位置）
                    Button(action: { tryDeny() }) { Text("拒绝") }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(denyReturnShortcut)
                    if !shouldHideAllowAll {
                        Button(action: { tryAllow() }) {
                            Label(allowLabel, systemImage: "checkmark.circle")
                        }
                        .help(phaseRequiresCmdClick ? "按住 ⌘ 点击允许" : "")
                        .buttonStyle(.bordered)
                        .keyboardShortcut(allowReturnShortcut)
                    }
                } else {
                    if !shouldHideAllowAll {
                        if HipsFooterPolicy.allowIsProminent(footerState) {
                            // 视觉主选可以在允许侧，但 Return 永不在（allowReturnShortcut 恒 nil）
                            Button(action: { tryAllow() }) {
                                Text("允许")
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(allowReturnShortcut)
                        } else {
                            // 主按钮锁拒绝时，"允许"作为副选；红阶段需 Command-Click
                            Button(action: { tryAllow() }) {
                                Label(allowLabel, systemImage: "checkmark.circle")
                            }
                            .help(phaseRequiresCmdClick ? "按住 ⌘ 点击允许" : "")
                            .buttonStyle(.bordered)
                            .keyboardShortcut(allowReturnShortcut)
                        }
                    }
                    if mainActionLocked {
                        Button(action: { tryDeny() }) { Text("拒绝") }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(denyReturnShortcut)
                    } else {
                        Button(action: { tryDeny() }) { Text("拒绝") }
                            .buttonStyle(.bordered)
                            .keyboardShortcut(denyReturnShortcut)
                    }
                }
            }
        }
    }

    /// SPEC-002 §4.8：多 issue 合并三按钮组（红线：含 Critical 时禁止渲染"全部允许"）。
    @ViewBuilder
    private var mergedActionButtons: some View {
        if MergedDecisionBuilder.canAllowAll(request.issues) {
            if swappedLayout {
                Button(action: { tryMerged(.denyAll) }) { Text("拒绝全部") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(denyReturnShortcut)
                Button(action: { tryMerged(.allowAll) }) { Text("全部允许") }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(allowReturnShortcut)
            } else {
                // 无 Critical：拒绝全部（副）+ 全部允许（视觉主选）。
                // P0-2：Return 仍绑拒绝全部，允许类按钮永不挂 keyboardShortcut。
                Button(action: { tryMerged(.denyAll) }) { Text("拒绝全部") }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(denyReturnShortcut)
                Button(action: { tryMerged(.allowAll) }) { Text("全部允许") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(allowReturnShortcut)
            }
        } else {
            if swappedLayout {
                Button(action: { tryMerged(.denyAll) }) { Text("拒绝全部") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(denyReturnShortcut)
                allowNonCriticalButton
            } else {
                // 有 Critical：仅允许非 Critical 项（副）+ 拒绝全部（主，Return 默认拒绝）
                allowNonCriticalButton
                Button(action: { tryMerged(.denyAll) }) { Text("拒绝全部") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(denyReturnShortcut)
            }
        }
    }

    private var allowNonCriticalButton: some View {
        Button(action: { tryMerged(.allowNonCritical) }) {
            Text("仅允许非 Critical 项（\(MergedDecisionBuilder.nonCriticalCount(request.issues)) 项）")
        }
        .buttonStyle(.bordered)
        .keyboardShortcut(allowReturnShortcut)
        .disabled(MergedDecisionBuilder.nonCriticalCount(request.issues) == 0)
    }

    private func tryMerged(_ action: MergedAction) {
        guard !isClickSwallowed() else { return }
        onMergedDecision(action)
    }

    private var mainActionLocked: Bool {
        Recommendation.mainActionLocksToDeny(request.recommendation)
    }

    /// P0-2/P0-3：所有 footer 按钮的 Return 绑定都经 HipsFooterPolicy.bindsReturnKey 派生，
    /// 杜绝手写漂移——允许类恒 nil（键盘无法触发允许），拒绝类恒 .defaultAction（Return 绑拒绝）。
    /// 新增任何 footer 按钮都必须用这两个属性挂快捷键，不得手写 defaultAction 绑定。
    private var allowReturnShortcut: KeyboardShortcut? {
        HipsFooterPolicy.bindsReturnKey(role: .allow) ? .defaultAction : nil
    }

    private var denyReturnShortcut: KeyboardShortcut? {
        HipsFooterPolicy.bindsReturnKey(role: .deny) ? .defaultAction : nil
    }

    /// footer 键盘/布局策略输入（唯一规则见 HipsFooterPolicy，Core 矩阵测试锚定）。
    private var footerState: HipsFooterPolicy.FooterState {
        .init(
            mainActionLocked: mainActionLocked,
            phaseRequiresCmdClick: phaseRequiresCmdClick,
            swappedLayout: swappedLayout,
            merged: request.merged,
            canAllowAll: request.merged && MergedDecisionBuilder.canAllowAll(request.issues)
        )
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
        // 阈值公式唯一来源在 HipsPhase.resolve（核心库纯函数），View 不重复实现。
        HipsPhase.resolve(
            remaining: Double(appState.holdRemainingSeconds),
            total: Double(request.timeoutSeconds)
        )
    }

    private var allowLabel: String {
        phaseRequiresCmdClick ? "按住 ⌘ 点击允许" : "允许"
    }

    private func tryAllow() {
        guard !isClickSwallowed() else { return }
        if phaseRequiresCmdClick {
            // P0-3：red 阶段允许必须是「带 ⌘ 的鼠标点击」；键盘触发一律不放行（CmdClickGate）
            let event = NSApp.currentEvent
            let isMouseClick = event?.type == .leftMouseUp || event?.type == .leftMouseDown
            let hasCommand = event?.modifierFlags.contains(.command) ?? false
            guard CmdClickGate.permitsAllow(
                phaseRequiresCmdClick: true,
                eventIsMouseClick: isMouseClick,
                hasCommandModifier: hasCommand
            ) else { return }
        }
        onDecision(
            .allow,
            request.allowRemember && rememberChecked,
            contextHint.isEmpty ? nil : contextHint,
            currentPhase
        )
    }

    private func tryDeny() {
        guard !isClickSwallowed() else { return }
        onDecision(.deny, false, contextHint.isEmpty ? nil : contextHint, currentPhase)
    }
}
