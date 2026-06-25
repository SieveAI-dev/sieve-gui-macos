import SwiftUI

public struct DaemonSettingsView: View {
    @ObservedObject var appState: AppState
    let ipcClient: IPCClient

    @State private var health: HealthResultDTO?
    @State private var healthFetchedAt: Date?

    public var body: some View {
        Form {
            Section("运行状态") {
                LabeledContent("daemon 版本") { Text(appState.daemonVersion ?? "—") }
                LabeledContent("协议版本") { Text(appState.protocolVersion ?? "—") }
                LabeledContent("Preset") { Text(appState.preset.rawValue) }
                LabeledContent("audit.db schema") {
                    if appState.auditDbUserVersion > 0 {
                        Text("v\(appState.auditDbUserVersion)") + Text(appState.auditSchemaWarning ? "（未知版本）" : "").foregroundColor(.orange)
                    } else {
                        Text("—")
                    }
                }
                LabeledContent("最后握手") {
                    Text(appState.lastHandshakeAt.map { dateLabel($0) } ?? "—")
                }
            }
            Section(listenersHeader) {
                if let listeners = listenerRows, !listeners.isEmpty {
                    ForEach(listeners) { l in
                        LabeledContent("\(l.providerId)（:\(l.port)）") {
                            Text(l.protocol).font(.system(.caption, design: .monospaced))
                        }
                    }
                } else if health == nil {
                    Text("点击下方 “Health Check” 拉取 listener 列表").foregroundStyle(.secondary).font(.callout)
                } else {
                    Text("daemon 暂未上报 listener").foregroundStyle(.secondary).font(.callout)
                }
            }
            Section("配置") {
                LabeledContent("配置文件") { Text("~/.sieve/config.toml").font(.system(.caption, design: .monospaced)) }
                LabeledContent("audit.db") { Text("~/.sieve/audit.db").font(.system(.caption, design: .monospaced)) }
                LabeledContent("ipc socket") { Text("~/.sieve/ipc.sock").font(.system(.caption, design: .monospaced)) }
            }
            Section("操作") {
                HStack(spacing: 12) {
                    Button("Reload Config") {
                        Task {
                            do {
                                let data = try await ipcClient.sendRequest(id: UUID().uuidString, method: "sieve.reload_config")
                                if let r = try? JSONDecoder().decode(ReloadConfigResult.self, from: data) {
                                    await GUILog.shared.info("reload_config ok: system=\(r.systemRulesCount) user=\(r.userRulesCount) errors=\(r.userRulesErrors.count)", category: "settings")
                                }
                            } catch {
                                await GUILog.shared.warn("reload_config failed: \(error)", category: "settings")
                            }
                        }
                    }
                    Button("Health Check") { Task { await fetchHealth() } }
                    Button("运行 sieve doctor…") {
                        runSieveDoctor()
                    }
                }
                .disabled(isDisconnected)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            // 首次进入时拉一次，让 Listeners 段非空。
            await fetchHealth()
        }
    }

    private var listenersHeader: String {
        if let at = healthFetchedAt {
            return "Listeners（health @ \(dateLabel(at))）"
        }
        return "Listeners"
    }

    /// 优先用 listeners[]；旧 daemon 退化到 listen 单值。
    private var listenerRows: [HealthResultDTO.ListenerSnapshot]? {
        health?.effectiveListeners
    }

    private func fetchHealth() async {
        do {
            let data = try await ipcClient.sendRequest(id: UUID().uuidString, method: "sieve.health")
            let dto = try JSONDecoder().decode(HealthResultDTO.self, from: data)
            await MainActor.run {
                self.health = dto
                self.healthFetchedAt = Date()
            }
        } catch {
            await GUILog.shared.warn("sieve.health failed: \(error)", category: "settings")
        }
    }

    private var isDisconnected: Bool {
        if case .disconnected = appState.daemonStatus { return true }
        return false
    }

    private func dateLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: d)
    }

    private func runSieveDoctor() {
        guard let bin = SieveBinaryLocator.resolve() else {
            Task { await GUILog.shared.warn("找不到 sieve 可执行文件，无法运行 doctor", category: "settings") }
            return
        }
        let task = Process()
        task.launchPath = bin
        task.arguments = ["doctor"]
        try? task.run()
    }
}
