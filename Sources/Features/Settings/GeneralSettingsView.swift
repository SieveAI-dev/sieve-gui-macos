import SwiftUI

public struct GeneralSettingsView: View {
    @ObservedObject var appState: AppState

    public var body: some View {
        Form {
            Section("启动") {
                Toggle("登录时启动 Sieve GUI", isOn: $appState.settings.loginItemEnabled)
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
    }
}
