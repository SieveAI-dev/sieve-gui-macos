import SwiftUI
import ServiceManagement
import AppKit

public struct GeneralSettingsView: View {
    @ObservedObject var appState: AppState
    @State private var loginItemError: String? = nil
    @State private var showLoginItemAlert: Bool = false
    @State private var languageRestartPending: Bool = false
    @State private var soundPreviewError: String? = nil

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
                .onChange(of: appState.settings.appearance) { value in
                    applyAppearance(value)
                }
                Picker("语言", selection: $appState.settings.language) {
                    Text("跟随系统").tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                .onChange(of: appState.settings.language) { value in
                    applyLanguage(value)
                }
                if languageRestartPending {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.secondary)
                        Text("语言已保存，重启 Sieve GUI 后生效。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                Text("仅影响 GUI 文案；daemon 推送的 rule title 由 daemon 处理。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("减少动效", selection: $appState.settings.reduceMotionOverride) {
                    Text("跟随系统").tag("system")
                    Text("始终减少").tag("always")
                    Text("禁用减少").tag("never")
                }
            }
            Section("提示音与 Toast") {
                HStack {
                    Toggle("HIPS 弹窗提示音", isOn: $appState.settings.hipsSoundEnabled)
                    Spacer()
                    Button("试听") {
                        previewHipsSound()
                    }
                }
                Text("HIPS 弹窗触发时播放（\(appState.settings.hipsSoundName)）。")
                    .font(.caption).foregroundStyle(.secondary)
                if let soundPreviewError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(soundPreviewError).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                Stepper(value: $appState.settings.toastDurationSeconds, in: 3...10) {
                    Text("Toast 时长：\(appState.settings.toastDurationSeconds)s")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            // 视图出现时同步一次当前主题，保证设置与实际渲染一致
            applyAppearance(appState.settings.appearance)
        }
        .alert("开机启动注册失败", isPresented: $showLoginItemAlert) {
            Button("去 System Settings 启用") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
            }
            Button("知道了", role: .cancel) {}
        } message: {
            Text(loginItemError ?? "请前往 System Settings → General → Login Items 手动启用 Sieve GUI。")
        }
    }

    private func previewHipsSound() {
        let requestedName = appState.settings.hipsSoundName
        let sound = NSSound(named: NSSound.Name(requestedName)) ?? NSSound(named: NSSound.Name(UserSettings.default.hipsSoundName))
        guard let sound else {
            soundPreviewError = "无法播放提示音：\(requestedName)"
            return
        }
        soundPreviewError = nil
        sound.stop()
        sound.play()
    }

    /// 应用主题：直接设置 NSApp.appearance，即时生效。
    /// system → nil（跟随系统）/ light → aqua / dark → darkAqua。
    private func applyAppearance(_ value: String) {
        let appearance: NSAppearance?
        switch value {
        case "light":
            appearance = NSAppearance(named: .aqua)
        case "dark":
            appearance = NSAppearance(named: .darkAqua)
        default:
            appearance = nil
        }
        NSApp.appearance = appearance
    }

    /// 应用语言：写入 AppleLanguages UserDefaults。
    /// macOS 运行时切 bundle 不可靠，务实做法是写入偏好 + 提示重启生效。
    private func applyLanguage(_ value: String) {
        let defaults = UserDefaults.standard
        if value == "system" {
            // 跟随系统：移除覆盖，恢复系统语言顺序
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([value], forKey: "AppleLanguages")
        }
        languageRestartPending = true
        Task { @MainActor in
            await GUILog.shared.info("Language preference set to \(value); restart required", category: "settings")
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
