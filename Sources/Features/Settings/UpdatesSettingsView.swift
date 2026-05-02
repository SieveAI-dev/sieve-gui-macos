import SwiftUI

public struct UpdatesSettingsView: View {
    @ObservedObject var appState: AppState

    public var body: some View {
        Form {
            Section("自动更新") {
                Toggle("启动时自动检查更新", isOn: $appState.settings.autoCheckUpdates)
                Button("立即检查更新") {
                    SparkleUpdaterBridge.shared.checkForUpdates()
                }
            }
            Section("当前版本") {
                LabeledContent("Sieve GUI") { Text(currentVersion) }
                LabeledContent("daemon") { Text(appState.daemonVersion ?? "—") }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var currentVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}

public struct AboutSettingsView: View {
    @State private var exporting: Bool = false
    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Sieve GUI").font(.title.weight(.semibold))
            Text(currentVersion).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                Button(exporting ? "正在导出…" : "导出诊断包…") {
                    Task { await exportDiagnostic() }
                }
                .disabled(exporting)
                Button("重新运行引导") {
                    WindowManager.shared.openOnboarding()
                }
            }
            HStack(spacing: 16) {
                Link("帮助文档", destination: URL(string: "https://sieve.local/docs")!)
                Link("反馈", destination: URL(string: "https://sieve.local/feedback")!)
                Link("开源声明", destination: URL(string: "https://sieve.local/licenses")!)
            }
            .font(.caption)
            Spacer()
        }
        .padding()
    }

    private var currentVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(v) (\(b))"
    }

    private func exportDiagnostic() async {
        exporting = true
        defer { exporting = false }
        let result = await DiagnosticPackager.shared.exportRedacted()
        if let url = result {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
