import SwiftUI

public struct DetectionPresetView: View {
    @ObservedObject var appState: AppState
    let ipcClient: IPCClient

    @State private var pendingPreset: Preset?
    @State private var showConfirm: Bool = false

    // Custom 模式规则覆盖：rule_id → 当前编辑中的 override
    @State private var ruleOverrides: [String: RuleOverride] = [:]

    // list_rules 状态
    @State private var liveRules: [RuleSummary] = []
    @State private var rulesLoading: Bool = false
    @State private var rulesError: String?
    @State private var rulesUnavailable: Bool = false   // -32601 降级标记

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Detection Preset").font(.headline)
            HStack(spacing: 8) {
                ForEach(Preset.allCases, id: \.rawValue) { p in
                    presetCard(p)
                }
            }
            Divider()
            Text("规则总览").font(.headline)
            if appState.preset == .custom {
                customRuleTable
            } else {
                ruleOverviewSection
            }
            Spacer()
        }
        .padding()
        .alert("切换 Preset", isPresented: $showConfirm) {
            Button("取消", role: .cancel) { pendingPreset = nil }
            Button("确认切换") {
                guard let p = pendingPreset else { return }
                applyPreset(p)
            }
        } message: {
            Text("切换后会立即生效，正在弹出的 HIPS 弹窗会保留。")
        }
        .disabled(isDisconnected)
        .onAppear {
            initOverridesIfNeeded()
            if !rulesUnavailable && liveRules.isEmpty {
                Task { await refreshRules() }
            }
        }
        .onChange(of: appState.preset) { _ in initOverridesIfNeeded() }
    }

    // MARK: - Preset Card

    private func presetCard(_ p: Preset) -> some View {
        let selected = appState.preset == p
        return Button {
            pendingPreset = p
            showConfirm = true
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(p.rawValue).font(.subheadline.weight(.semibold))
                Text(presetDescription(p)).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func presetDescription(_ p: Preset) -> String {
        switch p {
        case .strict: return "全员严格，最多干预。"
        case .standard: return "默认推荐，平衡。"
        case .relaxed: return "宽松，仅 critical 弹窗。"
        case .custom: return "自定义覆盖。"
        }
    }

    // MARK: - Custom 模式内联编辑表格

    private var customRuleTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Dir").font(.caption.weight(.semibold)).frame(width: 44, alignment: .leading)
                Text("rule_id").font(.caption.weight(.semibold)).frame(width: 156, alignment: .leading)
                Text("severity").font(.caption.weight(.semibold)).frame(width: 70, alignment: .leading)
                Text("timeout(s)").font(.caption.weight(.semibold)).frame(width: 80, alignment: .leading)
                Text("default").font(.caption.weight(.semibold)).frame(width: 90, alignment: .leading)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(knownRules, id: \.id) { rule in
                        customRuleRow(rule)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func customRuleRow(_ rule: RuleDisplayItem) -> some View {
        let lock = rule.criticalLock
        let override = Binding<RuleOverride>(
            get: { ruleOverrides[rule.id] ?? RuleOverride(ruleId: rule.id, timeoutSeconds: rule.defaultTimeout, defaultOnTimeout: rule.defaultOnTimeout) },
            set: { newVal in ruleOverrides[rule.id] = newVal }
        )
        HStack {
            // Dir
            Text(rule.direction).font(.system(.caption2, design: .monospaced)).frame(width: 44, alignment: .leading)
            // rule_id + lock icon
            HStack(spacing: 4) {
                if lock { Image(systemName: "lock.fill").foregroundStyle(.secondary).font(.caption2) }
                Text(rule.id).font(.system(.caption, design: .monospaced))
            }
            .frame(width: 156, alignment: .leading)
            // severity
            Text(rule.severity).font(.caption2).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            // timeout_seconds 编辑
            if lock {
                Text("\(override.wrappedValue.timeoutSeconds)s")
                    .font(.caption2)
                    .frame(width: 80, alignment: .leading)
                    .foregroundStyle(.secondary)
            } else {
                timeoutField(override: override, ruleId: rule.id)
                    .frame(width: 80, alignment: .leading)
            }
            // default_on_timeout 编辑
            if lock {
                Text(override.wrappedValue.defaultOnTimeout)
                    .font(.caption2)
                    .frame(width: 90, alignment: .leading)
                    .foregroundStyle(.secondary)
            } else {
                defaultPicker(override: override, ruleId: rule.id)
                    .frame(width: 90, alignment: .leading)
            }
            Spacer()
            if lock {
                Text("critical_lock").font(.caption2).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .disabled(lock)
        .opacity(lock ? 0.5 : 1.0)
        .help(lock ? "Critical 规则强制锁定，不可修改 [SPEC §5.4]" : "")
    }

    /// 超时秒数输入框（30~600，整数）。失焦后 debounce 500ms 发 IPC。
    private func timeoutField(override: Binding<RuleOverride>, ruleId: String) -> some View {
        let textBinding = Binding<String>(
            get: { "\(override.wrappedValue.timeoutSeconds)" },
            set: { str in
                if let v = Int(str), v >= 30, v <= 600 {
                    override.wrappedValue.timeoutSeconds = v
                    scheduleOverrideCommit(ruleId: ruleId)
                }
            }
        )
        return TextField("30-600", text: textBinding)
            .textFieldStyle(.squareBorder)
            .font(.caption2)
            .frame(width: 60)
    }

    /// default_on_timeout 选择器。
    private func defaultPicker(override: Binding<RuleOverride>, ruleId: String) -> some View {
        let dotBinding = Binding<String>(
            get: { override.wrappedValue.defaultOnTimeout },
            set: { v in
                override.wrappedValue.defaultOnTimeout = v
                scheduleOverrideCommit(ruleId: ruleId)
            }
        )
        return Picker("", selection: dotBinding) {
            Text("block").tag("block")
            Text("allow").tag("allow")
            Text("redact").tag("redact")
        }
        .labelsHidden()
        .font(.caption2)
    }

    // MARK: - 规则总览区域（非 Custom 模式，接 list_rules 实时数据）

    private var ruleOverviewSection: some View {
        Group {
            if rulesUnavailable {
                // -32601：daemon 版本过旧
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("daemon 版本过旧，不支持规则总览（需升级 daemon）")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let err = rulesError {
                // 其他错误 / -32006 重试中
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    Text(err).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重试") { Task { await refreshRules() } }
                        .font(.caption).buttonStyle(.borderless)
                }
                .padding(8)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if rulesLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("加载规则列表…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
            } else {
                liveRuleTable
            }
        }
    }

    // MARK: - 实时规则 Table（7 列）

    private var liveRuleTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text("title").font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("severity").font(.caption.weight(.semibold)).frame(width: 64, alignment: .leading)
                Text("direction").font(.caption.weight(.semibold)).frame(width: 60, alignment: .leading)
                Text("disposition").font(.caption.weight(.semibold)).frame(width: 90, alignment: .leading)
                Text("timeout").font(.caption.weight(.semibold)).frame(width: 56, alignment: .trailing)
                Text("default").font(.caption.weight(.semibold)).frame(width: 56, alignment: .trailing)
                Text("on").font(.caption.weight(.semibold)).frame(width: 34, alignment: .center)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            Divider()
            if liveRules.isEmpty {
                Text("（暂无规则数据）").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(liveRules) { rule in
                            liveRuleRow(rule)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            HStack {
                Spacer()
                Button {
                    Task { await refreshRules() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(rulesLoading)
            }
        }
    }

    private func liveRuleRow(_ rule: RuleSummary) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if rule.criticalLock {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
                Text(rule.title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // severity chip
            Text(rule.severity.rawValue)
                .font(.system(.caption2, design: .monospaced))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(severityColor(rule.severity).opacity(0.15))
                .foregroundStyle(severityColor(rule.severity))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .frame(width: 64, alignment: .leading)

            // direction
            Text(rule.direction.rawValue)
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 60, alignment: .leading)

            // disposition
            Text(rule.disposition.rawValue)
                .font(.system(.caption2, design: .monospaced))
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)

            // timeout
            if let t = rule.timeoutSeconds {
                Text("\(t)s").font(.caption2).frame(width: 56, alignment: .trailing)
            } else {
                Text("—").font(.caption2).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            }

            // default_on_timeout
            if let dot = rule.defaultOnTimeout {
                Text(dot.rawValue).font(.caption2).frame(width: 56, alignment: .trailing)
            } else {
                Text("—").font(.caption2).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            }

            // enabled toggle (read-only display)
            Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                .font(.caption2)
                .foregroundStyle(rule.enabled ? Color.green : Color.secondary)
                .frame(width: 34, alignment: .center)
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(rule.criticalLock ? Color.red.opacity(0.04) : Color.clear)
        .disabled(rule.criticalLock)
        .opacity(rule.criticalLock ? 0.65 : 1.0)
        .help(rule.criticalLock ? "Critical 规则强制锁定，不可修改 [SPEC §5.4]" : "")
    }

    private func severityColor(_ s: Severity) -> Color {
        switch s {
        case .critical: return .red
        case .high: return .orange
        case .medium: return .yellow
        case .low: return .blue
        }
    }

    // MARK: - 规则数据

    struct RuleDisplayItem: Identifiable {
        let id: String          // rule_id
        let direction: String
        let severity: String
        let criticalLock: Bool
        let defaultTimeout: Int
        let defaultOnTimeout: String  // block / allow / redact
    }

    private var knownRules: [RuleDisplayItem] {
        [
            RuleDisplayItem(id: "IN-CR-01",  direction: "IN",  severity: "critical", criticalLock: true,  defaultTimeout: 30, defaultOnTimeout: "block"),
            RuleDisplayItem(id: "IN-CR-05",  direction: "IN",  severity: "critical", criticalLock: true,  defaultTimeout: 30, defaultOnTimeout: "block"),
            RuleDisplayItem(id: "OUT-07",    direction: "OUT", severity: "critical", criticalLock: true,  defaultTimeout: 30, defaultOnTimeout: "block"),
            RuleDisplayItem(id: "OUT-09",    direction: "OUT", severity: "critical", criticalLock: true,  defaultTimeout: 30, defaultOnTimeout: "block"),
            RuleDisplayItem(id: "OUT-01",    direction: "OUT", severity: "high",     criticalLock: false, defaultTimeout: 30, defaultOnTimeout: "block"),
            RuleDisplayItem(id: "OUT-02",    direction: "OUT", severity: "medium",   criticalLock: false, defaultTimeout: 60, defaultOnTimeout: "allow"),
        ]
    }

    private var knownCriticalRules: [RuleDisplayItem] {
        knownRules.filter(\.criticalLock)
    }

    // MARK: - IPC

    /// 500ms debounce 工作项：key = rule_id。
    @State private var debounceWork: [String: DispatchWorkItem] = [:]

    private func scheduleOverrideCommit(ruleId: String) {
        debounceWork[ruleId]?.cancel()
        let work = DispatchWorkItem { [self] in
            commitOverride(ruleId: ruleId)
        }
        debounceWork[ruleId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func commitOverride(ruleId: String) {
        guard let override = ruleOverrides[ruleId] else { return }
        let prevOverride = override
        let requestId = UUID().uuidString
        Task {
            await ipcClient.registerMutatingRequest(requestId)   // 注册先于发送，避免 echo 漏判
            do {
                _ = try await ipcClient.sendRequest(
                    id: requestId,
                    method: "sieve.set_preset_overrides",
                    params: SetPresetOverridesParams(
                        ruleId: ruleId,
                        timeoutSeconds: prevOverride.timeoutSeconds,
                        defaultOnTimeout: prevOverride.defaultOnTimeout
                    )
                )
                ipcClient.unregisterMutatingRequest(requestId)
            } catch {
                ipcClient.unregisterMutatingRequest(requestId)
                // 失败回滚：恢复初始默认值
                await MainActor.run {
                    ruleOverrides[ruleId] = nil  // 清空 → Binding fallback 到 defaultTimeout
                }
                await GUILog.shared.warn("set_preset_overrides failed ruleId=\(ruleId): \(error)", category: "settings")
            }
        }
    }

    private func initOverridesIfNeeded() {
        if appState.preset == .custom {
            // 初始化时不覆盖已有编辑，只补全缺失项
            for rule in knownRules where !rule.criticalLock && ruleOverrides[rule.id] == nil {
                ruleOverrides[rule.id] = RuleOverride(
                    ruleId: rule.id,
                    timeoutSeconds: rule.defaultTimeout,
                    defaultOnTimeout: rule.defaultOnTimeout
                )
            }
        }
    }

    // MARK: - list_rules IPC

    func refreshRules() async {
        await MainActor.run {
            rulesLoading = true
            rulesError = nil
        }
        do {
            let data = try await ipcClient.sendRequest(id: UUID().uuidString, method: "sieve.list_rules")
            let result = try JSONDecoder().decode(ListRulesResult.self, from: data)
            await MainActor.run {
                liveRules = result.rules
                rulesLoading = false
            }
        } catch let err as InflightQueue.AwaitError {
            switch err {
            case .rpcError(let code, let message, _):
                if code == -32006 {
                    // rules_loading：5s 后自动重试
                    await MainActor.run {
                        rulesLoading = false
                        rulesError = "规则加载中，请稍后重试…"
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await refreshRules()
                } else if code == -32601 {
                    // method_not_found：daemon 版本过旧，降级
                    await MainActor.run {
                        rulesLoading = false
                        rulesUnavailable = true
                        rulesError = nil
                    }
                    await GUILog.shared.warn("sieve.list_rules -32601: daemon 版本过旧", category: "settings")
                } else {
                    await MainActor.run {
                        rulesLoading = false
                        rulesError = "加载失败：\(message)"
                    }
                }
            default:
                await MainActor.run {
                    rulesLoading = false
                    rulesError = "加载失败，请检查 daemon 连接状态"
                }
            }
        } catch {
            await MainActor.run {
                rulesLoading = false
                rulesError = "解码失败：\(error.localizedDescription)"
            }
        }
    }

    private var isDisconnected: Bool {
        if case .disconnected = appState.daemonStatus { return true }
        return false
    }

    private func applyPreset(_ p: Preset) {
        let id = UUID().uuidString
        let previousPreset = appState.preset
        appState.updatePreset(p)         // 乐观更新
        pendingPreset = nil
        Task {
            await ipcClient.registerMutatingRequest(id)   // 注册先于发送，避免 echo 漏判
            do {
                _ = try await ipcClient.sendRequest(id: id, method: "sieve.set_preset", params: SetPresetParams(mode: p.rawValue))
                ipcClient.unregisterMutatingRequest(id)
            } catch {
                ipcClient.unregisterMutatingRequest(id)
                // critical_lock_violation / 其他错误 → 回滚
                await MainActor.run { appState.updatePreset(previousPreset) }
                await GUILog.shared.warn("set_preset failed: \(error)", category: "settings")
            }
        }
    }
}

// RuleOverride 定义见 Sources/Models/RuleOverride.swift
