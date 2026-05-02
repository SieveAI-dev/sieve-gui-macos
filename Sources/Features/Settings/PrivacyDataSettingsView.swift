import SwiftUI

public struct PrivacyDataSettingsView: View {
    @ObservedObject var appState: AppState
    let ipcClient: IPCClient

    @State private var showGraylist: Bool = false
    @State private var showClearConfirm: Bool = false

    public var body: some View {
        Form {
            Section("默认渲染") {
                Toggle("历史记录默认脱敏", isOn: $appState.settings.historyMaskByDefault)
            }
            Section("灰名单") {
                Button("管理灰名单…") { showGraylist = true }
            }
            Section("危险操作") {
                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("清空历史…", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showGraylist) {
            GraylistSheetView(ipcClient: ipcClient, isPresented: $showGraylist)
        }
        .alert("清空历史", isPresented: $showClearConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认清空", role: .destructive) {
                Task { await clearHistoryWithUnlock() }
            }
        } message: {
            Text("此操作不可逆，且需要 Touch ID 二次确认。")
        }
    }

    private func clearHistoryWithUnlock() async {
        let ok = await TouchIDService.shared.authenticate(reason: "确认清空 Sieve 历史记录")
        guard ok else { return }
        // 清空通过 daemon API 完成（GUI 不写 audit.db）。这里仅占位：未来添加 sieve.purge_history 方法。
        await GUILog.shared.warn("用户触发清空历史（待 daemon 实现 sieve.purge_history）")
    }
}

public struct GraylistSheetView: View {
    let ipcClient: IPCClient
    @Binding var isPresented: Bool
    @State private var entries: [GraylistEntry] = []
    @State private var loading: Bool = false

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("灰名单管理").font(.headline)
                Spacer()
                Button("关闭") { isPresented = false }
            }
            .padding()
            Divider()
            if loading {
                ProgressView().padding()
            } else if entries.isEmpty {
                Text("暂无灰名单条目").foregroundStyle(.secondary).padding()
            } else {
                List(entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.ruleId).font(.callout.weight(.medium))
                            MaskedField(entry.fingerprint, style: .prefix4Suffix4, isUnlocked: false)
                                .font(.caption)
                            if let hint = entry.contextHint {
                                Text(hint).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("命中 \(entry.triggerCount) 次").font(.caption).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            Task { await remove(entry.fingerprint) }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(minHeight: 240)
            }
        }
        .frame(width: 480, height: 360)
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            let data = try await ipcClient.sendRequest(id: UUID().uuidString, method: "sieve.list_graylist")
            let resp = try JSONDecoder().decode(GraylistResponse.self, from: data)
            entries = resp.entries
        } catch {
            await GUILog.shared.warn("list_graylist failed: \(error)", category: "settings")
            entries = []
        }
    }

    private func remove(_ fp: String) async {
        ipcClient.sendRequestAndForget(id: UUID().uuidString, method: "sieve.remove_graylist", params: ["fingerprint": fp])
        entries.removeAll { $0.fingerprint == fp }
    }
}
