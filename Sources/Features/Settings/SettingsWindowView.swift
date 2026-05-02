import SwiftUI

public struct SettingsWindowView: View {
    @ObservedObject var appState: AppState
    let ipcClient: IPCClient

    public init(appState: AppState, ipcClient: IPCClient) {
        self.appState = appState
        self.ipcClient = ipcClient
    }

    public var body: some View {
        VStack(spacing: 0) {
            if case .disconnected(let reason) = appState.daemonStatus {
                DisconnectedBanner(reason: reason, onAction: nil)
            }
            TabView {
                GeneralSettingsView(appState: appState)
                    .tabItem { Label("通用", systemImage: "gearshape") }
                DetectionPresetView(appState: appState, ipcClient: ipcClient)
                    .tabItem { Label("检测", systemImage: "shield.lefthalf.filled") }
                PrivacyDataSettingsView(appState: appState, ipcClient: ipcClient)
                    .tabItem { Label("隐私", systemImage: "lock") }
                DaemonSettingsView(appState: appState, ipcClient: ipcClient)
                    .tabItem { Label("Daemon", systemImage: "bolt.horizontal") }
                UpdatesSettingsView(appState: appState)
                    .tabItem { Label("更新", systemImage: "arrow.triangle.2.circlepath") }
                AboutSettingsView()
                    .tabItem { Label("关于", systemImage: "info.circle") }
            }
            .padding(.top, 4)
        }
        .frame(width: 720, height: 540)
    }
}
