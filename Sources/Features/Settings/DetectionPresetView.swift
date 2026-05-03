import SwiftUI

public struct DetectionPresetView: View {
    @ObservedObject var appState: AppState
    let ipcClient: IPCClient

    @State private var pendingPreset: Preset?
    @State private var showConfirm: Bool = false

    // Custom 模式规则覆盖：rule_id → 当前编辑中的 override
    @State private var ruleOverrides: [String: RuleOverride] = [:]

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
                ruleTablePlaceholder
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
        .onAppear { initOverridesIfNeeded() }
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

    // MARK: - 非 Custom 模式占位

    private var ruleTablePlaceholder: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("规则列表加载需 daemon 提供 list_rules method（暂未实现）。当前仅展示已知 critical_lock 规则。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                ForEach(knownCriticalRules, id: \.id) { rule in
                    readonlyRuleRow(rule)
                }
            }
        }
    }

    private func readonlyRuleRow(_ rule: RuleDisplayItem) -> some View {
        HStack {
            if rule.criticalLock {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
            } else {
                Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
            }
            Text(rule.id).font(.system(.callout, design: .monospaced))
            if rule.criticalLock {
                Text("critical_lock").font(.caption).foregroundStyle(.red)
            }
            Spacer()
            HStack(spacing: 6) {
                Text("disposition")
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.gray.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 4))
                Text("timeout")
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.gray.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .disabled(rule.criticalLock).opacity(rule.criticalLock ? 0.4 : 1.0)
            .help(rule.criticalLock ? "Critical 规则强制锁定，不可修改 [SPEC §5.4]" : "")
        }
        .padding(.vertical, 4)
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
        ipcClient.registerMutatingRequest(requestId)
        Task {
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

    private var isDisconnected: Bool {
        if case .disconnected = appState.daemonStatus { return true }
        return false
    }

    private func applyPreset(_ p: Preset) {
        let id = UUID().uuidString
        let previousPreset = appState.preset
        appState.updatePreset(p)         // 乐观更新
        pendingPreset = nil
        ipcClient.registerMutatingRequest(id)
        Task {
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
