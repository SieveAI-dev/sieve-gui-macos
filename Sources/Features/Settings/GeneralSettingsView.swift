import SwiftUI
import ServiceManagement

public struct GeneralSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var loginItemError: String? = nil
    @State private var showLoginItemAlert: Bool = false

    public var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动 Sieve GUI", isOn: $appState.settings.loginItemEnabled)
                    .onChange(of: appState.settings.loginItemEnabled) { on in
                        applyLoginItem(on)
                    }
                if let err = loginItemError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(err).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("去 System Settings 启用") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color.orange.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            Section("外观") {
                Picker("主题", selection: $appState.settings.appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Picker("语言", selection: $appState.settings.language) {
                    Text("跟随系统").tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                Picker("减少动效", selection: $appState.settings.reduceMotionOverride) {
                    Text("跟随系统").tag("system")
                    Text("始终减少").tag("always")
                    Text("禁用减少").tag("never")
                }
            }
            Section("提示音与 Toast") {
                Toggle("HIPS 弹窗提示音", isOn: $appState.settings.hipsSoundEnabled)
                Stepper(value: $appState.settings.toastDurationSeconds, in: 3...10) {
                    Text("Toast 时长：\(appState.settings.toastDurationSeconds)s")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .alert("开机启动注册失败", isPresented: $showLoginItemAlert) {
            Button("去 System Settings 启用") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
            }
            Button("知道了", role: .cancel) {}
        } message: {
            Text(loginItemError ?? "请前往 System Settings → General → Login Items 手动启用 Sieve GUI。")
        }
    }

    private func applyLoginItem(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if on {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                // 注册成功，清除错误状态
                loginItemError = nil
            } catch {
                // 注册失败 → 回滚 toggle + 显示错误 banner + alert
                Task { @MainActor in
                    appState.settings.loginItemEnabled = !on
                    loginItemError = "开机启动注册失败：\(error.localizedDescription)。请去 System Settings → General → Login Items 手动启用。"
                    showLoginItemAlert = true
                    await GUILog.shared.warn("SMAppService register/unregister failed: \(error.localizedDescription)", category: "settings")
                }
            }
        }
    }
}
