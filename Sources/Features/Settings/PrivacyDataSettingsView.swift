import SwiftUI

public struct PrivacyDataSettingsView: View {
    @ObservedObject var appState: AppState
    let ipcClient: IPCClient

    @State private var showGraylist: Bool = false
    @State private var showClearConfirm: Bool = false
    @State private var purging: Bool = false
    @State private var purgeResultMessage: String?
    @State private var showPurgeResult: Bool = false
    @State private var purgeErrorMessage: String?
    @State private var showPurgeError: Bool = false
    @State private var purgeUnavailable: Bool = false   // -32601 降级标记

    public var body: some View {
        Form {
            Section("默认渲染") {
                Toggle("历史记录默认脱敏", isOn: $appState.settings.historyMaskByDefault)
            }
            Section("灰名单") {
                Button("管理灰名单…") { showGraylist = true }
            }
            Section("危险操作") {
                VStack(alignment: .leading, spacing: 6) {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        HStack {
                            if purging {
                                ProgressView().scaleEffect(0.7).padding(.trailing, 2)
                            }
                            Label("清空历史…", systemImage: "trash")
                        }
                    }
                    .disabled(purging || purgeUnavailable)

                    if purgeUnavailable {
                        Text("daemon 版本过旧，不支持清空历史（需升级 daemon）")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
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
        .alert("清空完成", isPresented: $showPurgeResult) {
            Button("好") {}
        } message: {
            Text(purgeResultMessage ?? "")
        }
        .alert("清空失败", isPresented: $showPurgeError) {
            Button("好") {}
        } message: {
            Text(purgeErrorMessage ?? "")
        }
    }

    // MARK: - 清空历史流程（SPEC-005 §11B）

    func clearHistoryWithUnlock() async {
        // Step 1：Touch ID 二次确认
        let ok = await TouchIDService.shared.authenticate(reason: "确认清空 Sieve 历史记录")
        guard ok else {
            // Touch ID 失败 → 不调 IPC
            await GUILog.shared.warn("Touch ID 失败，清空历史已取消", category: "privacy")
            return
        }

        // Step 2：调 IPC sieve.purge_history
        let confirmedAt = Date()
        await MainActor.run { purging = true }
        do {
            let data = try await ipcClient.sendRequest(
                id: UUID().uuidString,
                method: "sieve.purge_history",
                params: PurgeHistoryParams(confirmedAt: confirmedAt)
            )
            let result = try JSONDecoder().decode(PurgeHistoryResult.self, from: data)
            await MainActor.run {
                purging = false
                // 成功：显示结果 + 广播刷新通知（History 窗口监听后 reload）
                purgeResultMessage = "已清空 \(result.rowsDeleted) 条历史记录"
                showPurgeResult = true
                NotificationCenter.default.post(name: .sieveHistoryPurged, object: nil)
            }
            await GUILog.shared.info("purge_history 成功：rows_deleted=\(result.rowsDeleted)", category: "privacy")
        } catch let err as InflightQueue.AwaitError {
            await MainActor.run { purging = false }
            switch err {
            case .rpcError(let code, let message, _):
                if code == -32007 {
                    // purge_in_progress：提示正在进行
                    await MainActor.run {
                        purgeErrorMessage = "清空操作正在进行中，请稍候"
                        showPurgeError = true
                    }
                } else if code == -32601 {
                    // method_not_found：daemon 版本过旧，降级禁用按钮
                    await MainActor.run {
                        purgeUnavailable = true
                    }
                    await GUILog.shared.warn("sieve.purge_history -32601: daemon 版本过旧", category: "privacy")
                } else {
                    await MainActor.run {
                        purgeErrorMessage = "清空失败：\(message)"
                        showPurgeError = true
                    }
                }
            default:
                await MainActor.run {
                    purgeErrorMessage = "清空失败，请检查 daemon 连接状态"
                    showPurgeError = true
                }
            }
        } catch {
            await MainActor.run {
                purging = false
                purgeErrorMessage = "清空失败：\(error.localizedDescription)"
                showPurgeError = true
            }
        }
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
                        Text("命中 \(entry.matchCountSince) 次").font(.caption).foregroundStyle(.secondary)
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
        ipcClient.sendRequestAndForget(id: UUID().uuidString, method: "sieve.remove_graylist", params: RemoveGraylistParams(fingerprint: fp))
        entries.removeAll { $0.fingerprint == fp }
    }
}
