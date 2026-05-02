import SwiftUI

public struct DetectionPresetView: View {
    @ObservedObject var appState: AppState
    let ipcClient: IPCClient

    @State private var pendingPreset: Preset?
    @State private var showConfirm: Bool = false

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
            ruleTablePlaceholder
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
    }

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

    private var ruleTablePlaceholder: some View {
        // 真实实现：拉取 daemon 规则集 + 内联编辑
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("规则列表加载需 daemon 提供 list_rules method（v1 暂未规定）。当前仅展示已知 critical_lock 规则。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                ForEach(["IN-CR-01", "IN-CR-05", "OUT-07", "OUT-09"], id: \.self) { id in
                    HStack {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        Text(id).font(.system(.callout, design: .monospaced))
                        Text("critical_lock").font(.caption).foregroundStyle(.red)
                        Spacer()
                    }
                }
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
                _ = try await ipcClient.sendRequest(id: id, method: "sieve.set_preset", params: ["mode": p.rawValue])
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
