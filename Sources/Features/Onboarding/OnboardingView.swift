import SwiftUI
import UserNotifications
import ServiceManagement

public struct OnboardingView: View {
    @ObservedObject var appState: AppState
    let ipcClient: IPCClient
    let onClose: () -> Void

    @State private var step: Int = 1
    @State private var doctorResults: [DoctorCheck] = []
    @State private var notifGranted: Bool = false
    @State private var loginItemEnabled: Bool = false
    @State private var selectedPreset: Preset = .standard

    public init(appState: AppState, ipcClient: IPCClient, onClose: @escaping () -> Void) {
        self.appState = appState
        self.ipcClient = ipcClient
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Divider()
            ScrollView { content.padding(24) }
        }
        .frame(width: 720, height: 520)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sieve 引导").font(.title3.weight(.semibold)).padding(16)
            Divider()
            ForEach(1...6, id: \.self) { i in
                stepRow(index: i, title: stepTitle(i))
            }
            Spacer()
        }
        .background(Color.gray.opacity(0.06))
    }

    private func stepRow(index: Int, title: String) -> some View {
        HStack(spacing: 8) {
            Group {
                if index < step { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                else if index == step { Image(systemName: "circle.fill").foregroundStyle(.tint) }
                else { Image(systemName: "circle").foregroundStyle(.tertiary) }
            }
            Text(title).font(.callout).foregroundStyle(index == step ? .primary : .secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func stepTitle(_ i: Int) -> String {
        ["欢迎", "环境检查", "通知权限", "开机启动", "Preset 选择", "完成"][i - 1]
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 1: welcomeStep
        case 2: doctorStep
        case 3: notificationStep
        case 4: loginItemStep
        case 5: presetStep
        case 6: finishStep
        default: EmptyView()
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("欢迎使用 Sieve").font(.largeTitle.weight(.semibold))
            Text("Sieve 通过本地代理拦截 Claude Code 与 Agent 的可疑行为，并通过 GUI 弹窗征求你的决策。")
            Spacer()
            HStack {
                Button("跳过（不推荐）") { confirmSkip() }
                Spacer()
                Button("继续") { step = 2 }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var doctorStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("环境检查").font(.title2.weight(.semibold))
            ForEach(doctorResults, id: \.name) { check in
                HStack {
                    Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.ok ? .green : .red)
                    Text(check.name)
                    Spacer()
                    if !check.ok { Button("修复") { runSetup() } }
                }
            }
            Spacer()
            HStack {
                Button("重新检查") { runDoctor() }
                Spacer()
                Button("继续") { step = 3 }
                    .buttonStyle(.borderedProminent)
                    .disabled(doctorResults.isEmpty || doctorResults.contains { !$0.ok })
            }
        }
        .onAppear { runDoctor() }
    }

    private var notificationStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("通知权限").font(.title2.weight(.semibold))
            Text("Sieve 在 GUI 不在前台时通过系统通知提醒你处理 HIPS 弹窗。")
            HStack {
                Image(systemName: notifGranted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(notifGranted ? .green : .secondary)
                Text(notifGranted ? "已授权" : "未授权")
            }
            Spacer()
            HStack {
                Button("稍后") { step = 4 }
                Spacer()
                Button("申请通知权限") {
                    Task {
                        notifGranted = await NotificationCenterAdapter.shared.requestAuthorization()
                        if notifGranted { step = 4 }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var loginItemStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("开机启动").font(.title2.weight(.semibold))
            Text("登录时自动启动 Sieve GUI（推荐）。可在 设置 → 通用 中关闭。")
            Toggle("登录时启动", isOn: $loginItemEnabled).onChange(of: loginItemEnabled) { on in
                applyLoginItem(on)
            }
            Spacer()
            HStack {
                Spacer()
                Button("继续") { step = 5 }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var presetStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preset 选择").font(.title2.weight(.semibold))
            ForEach([Preset.strict, .standard, .relaxed], id: \.rawValue) { p in
                Button { selectedPreset = p } label: {
                    HStack {
                        Image(systemName: selectedPreset == p ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading) {
                            Text(p.rawValue).font(.subheadline.weight(.semibold))
                            Text(presetDesc(p)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(selectedPreset == p ? Color.accentColor.opacity(0.1) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            Spacer()
            HStack {
                Spacer()
                Button("继续") {
                    ipcClient.sendRequestAndForget(id: UUID().uuidString, method: "sieve.set_preset", params: ["mode": selectedPreset.rawValue])
                    appState.updatePreset(selectedPreset)
                    step = 6
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("完成").font(.title2.weight(.semibold))
            Text("Sieve 已就绪。你可以从菜单栏图标随时打开设置、历史与调试窗口。")
            Spacer()
            HStack {
                Button("运行 demo") { /* 占位：发一个 evaluate 请求触发 demo 弹窗 */ }
                Spacer()
                Button("完成") {
                    appState.settings.onboardingCompletedAt = Date()
                    onClose()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - actions

    private func confirmSkip() {
        let alert = NSAlert()
        alert.messageText = "确定跳过引导？"
        alert.informativeText = "未完成的检查项可能导致 Sieve 无法正常工作。"
        alert.addButton(withTitle: "继续引导")
        alert.addButton(withTitle: "确定跳过")
        if alert.runModal() == .alertSecondButtonReturn {
            appState.settings.onboardingCompletedAt = Date()
            onClose()
        }
    }

    private func runDoctor() {
        Task {
            do {
                let data = try await ipcClient.sendRequest(id: UUID().uuidString, method: "sieve.health")
                let dto = try JSONDecoder().decode(HealthResultDTO.self, from: data)
                await MainActor.run {
                    self.doctorResults = dto.checks.map { DoctorCheck(name: $0.name + ($0.detail.map { "（\($0)）" } ?? ""), ok: $0.ok) }
                }
            } catch {
                // 失联：daemon 不通也展示一组占位条目，引导用户跑 sieve setup
                await MainActor.run {
                    self.doctorResults = [
                        DoctorCheck(name: "ipc.sock 可连接", ok: false),
                        DoctorCheck(name: "ANTHROPIC_BASE_URL 配置", ok: false),
                        DoctorCheck(name: "PreToolUse hook 注册", ok: false),
                        DoctorCheck(name: "launchd plist 存在", ok: false),
                        DoctorCheck(name: "Canary 自检", ok: false)
                    ]
                }
            }
        }
    }

    private func runSetup() {
        let p = Process()
        p.launchPath = "/usr/local/bin/sieve"
        p.arguments = ["setup"]
        try? p.run()
    }

    private func applyLoginItem(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if on { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                Task { await GUILog.shared.warn("login item toggle failed: \(error.localizedDescription)") }
            }
        }
    }

    private func presetDesc(_ p: Preset) -> String {
        switch p {
        case .strict: return "全员严格"
        case .standard: return "默认推荐"
        case .relaxed: return "宽松"
        case .custom: return "自定义"
        }
    }
}

public struct DoctorCheck: Sendable {
    public let name: String
    public let ok: Bool
}
