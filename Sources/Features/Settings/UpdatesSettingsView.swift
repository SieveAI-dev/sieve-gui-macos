import SwiftUI

public struct UpdatesSettingsView: View {
    @ObservedObject var appState: AppState
    private let updater: AppUpdater
    @State private var updateStatusMessage: String?

    public init(appState: AppState, updater: AppUpdater = SparkleUpdaterBridge.shared) {
        self.appState = appState
        self.updater = updater
    }

    public var body: some View {
        Form {
            Section("自动更新") {
                Toggle("启动时自动检查更新", isOn: $appState.settings.autoCheckUpdates)
                Button("立即检查更新") {
                    requestUpdateCheck()
                }
                if let updateStatusMessage {
                    Text(updateStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("当前版本") {
                LabeledContent("Sieve GUI") { Text(currentVersion) }
                LabeledContent("daemon") { Text(appState.daemonVersion ?? "—") }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            syncAutoCheckSetting(appState.settings.autoCheckUpdates)
        }
        .onChange(of: appState.settings.autoCheckUpdates) { newValue in
            syncAutoCheckSetting(newValue)
        }
    }

    private var currentVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }

    private func requestUpdateCheck() {
        updater.checkForUpdates()
        updateStatusMessage = "已请求检查更新"
    }

    private func syncAutoCheckSetting(_ enabled: Bool) {
        updater.isAutoCheckEnabled = enabled
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
                Link("帮助文档", destination: URL(string: "https://sieveai.dev/docs")!)
                Link("反馈", destination: URL(string: "https://github.com/sieveai/sieve-gui-macos/issues")!)
                Link("开源声明", destination: URL(string: "https://sieveai.dev/licenses")!)
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
