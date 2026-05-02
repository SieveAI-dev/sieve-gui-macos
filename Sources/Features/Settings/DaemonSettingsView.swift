import SwiftUI

public struct DaemonSettingsView: View {
    @ObservedObject var appState: AppState
    let ipcClient: IPCClient

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
                    Button("Health Check") {
                        Task {
                            _ = try? await ipcClient.sendRequest(id: UUID().uuidString, method: "sieve.health")
                        }
                    }
                    Button("运行 sieve doctor…") {
                        runSieveDoctor()
                    }
                }
                .disabled(isDisconnected)
            }
        }
        .formStyle(.grouped)
        .padding()
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
        let task = Process()
        task.launchPath = "/usr/local/bin/sieve"
        task.arguments = ["doctor"]
        try? task.run()
    }
}
