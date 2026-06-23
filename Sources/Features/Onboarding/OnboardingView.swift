import SwiftUI
import UserNotifications
import ServiceManagement

public struct OnboardingView: View {
    @ObservedObject var appState: AppState
    let ipcClient: IPCClient
    let skipBridge: OnboardingSkipBridge?
    let onClose: () -> Void

    @State private var step: Int = 1
    @State private var doctorResults: [DoctorCheck] = []
    @State private var notifGranted: Bool = false
    @State private var loginItemEnabled: Bool = false
    @State private var selectedPreset: Preset = .standard
    /// daemon 二进制找不到时为 true（场景 C），驱动「未安装」专用提示 + 禁用继续。
    @State private var daemonNotInstalled: Bool = false

    public init(appState: AppState, ipcClient: IPCClient, skipBridge: OnboardingSkipBridge? = nil, onClose: @escaping () -> Void) {
        self.appState = appState
        self.ipcClient = ipcClient
        self.skipBridge = skipBridge
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 200)
            Divider()
            ScrollView { content.padding(24) }
        }
        .frame(width: 720, height: 520)
        .onAppear {
            // 把 confirmSkip 暴露给窗口关闭按钮（WindowManager），共用同一条跳过路径。
            skipBridge?.confirmSkip = { confirmSkip() }
        }
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
            if daemonNotInstalled {
                daemonNotInstalledNotice
            } else {
                ForEach(doctorResults, id: \.name) { check in
                    HStack {
                        Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(check.ok ? .green : .red)
                        Text(check.name)
                        Spacer()
                        if !check.ok { Button("修复") { runSetup() } }
                    }
                }
            }
            Spacer()
            HStack {
                Button("重新检查") { runDoctor() }
                Spacer()
                Button("继续") { step = 3 }
                    .buttonStyle(.borderedProminent)
                    .disabled(daemonNotInstalled || doctorResults.isEmpty || doctorResults.contains { check in !check.ok })
            }
        }
        .onAppear { runDoctor() }
    }

    /// 场景 C：daemon 二进制未安装时的专用降级提示（SPEC-006 §4.4）。
    /// 不提供「运行 sieve setup」（无可执行文件），改提示重新安装完整 .dmg。
    private var daemonNotInstalledNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("Sieve daemon 未安装").font(.headline)
            }
            Text("未在 PATH 或常见路径找到 sieve 命令，且 ~/.sieve/ipc.sock 不存在。请确保你已安装完整的 Sieve（.dmg），再重试。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("打开下载页") {
                if let url = URL(string: "https://sieveai.dev/download") {
                    NSWorkspace.shared.open(url)
                }
            }
            Text("daemon 未安装时无法继续引导。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
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
                    ipcClient.sendRequestAndForget(id: UUID().uuidString, method: "sieve.set_preset", params: SetPresetParams(mode: selectedPreset.rawValue))
                    appState.updatePreset(selectedPreset)
                    step = 6
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @State private var demoRunning: Bool = false
    @State private var demoResult: String = ""

    private var finishStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("完成").font(.title2.weight(.semibold))
            Text("Sieve 已就绪。你可以从菜单栏图标随时打开设置、历史与调试窗口。")
            Text("试试下面的 demo：发一个包含 BIP39 助记词的示例 prompt，体验真实的 HIPS 弹窗拦截流程。")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !demoResult.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: demoResult.hasPrefix("✓") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(demoResult.hasPrefix("✓") ? .green : .orange)
                    Text(demoResult).font(.caption)
                }
            }
            Spacer()
            HStack {
                Button(demoRunning ? "请求中…" : "运行 demo") { runDemo() }
                    .disabled(demoRunning)
                Spacer()
                Button("完成") {
                    appState.settings.onboardingCompletedAt = Date()
                    onClose()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func runDemo() {
        demoRunning = true
        demoResult = ""
        // Demo payload: 触发 OUT-* 规则的 BIP39 助记词 + 地址片段
        let demoPayload = """
            transfer 0x71C7656EC7ab88b098defB751B7401B5f6d8976F amount=2.5 ETH
            seed: abandon ability able about above absent absorb abstract absurd abuse access accident
            """
        Task {
            do {
                _ = try await ipcClient.sendRequest(
                    id: UUID().uuidString,
                    method: "sieve.evaluate",
                    params: EvaluateParams(
                        direction: "outbound",
                        contentKind: "tool_use_input",
                        payload: demoPayload,
                        sourceAgent: "claude"
                    )
                )
                await MainActor.run {
                    demoRunning = false
                    demoResult = "✓ evaluate 请求已发送，如 daemon 判断命中规则将弹出 HIPS 弹窗"
                }
            } catch {
                await MainActor.run {
                    demoRunning = false
                    demoResult = "⚠ daemon 未连接，请先确保 sieve daemon 运行中（\(error.localizedDescription)）"
                }
            }
        }
    }

    // MARK: - actions

    private func confirmSkip() {
        let alert = NSAlert()
        alert.messageText = "确定跳过引导？"
        alert.informativeText = "未完成引导，下次启动会再次出现。未完成的检查项可能导致 Sieve 无法正常工作。"
        alert.addButton(withTitle: "继续引导")
        alert.addButton(withTitle: "确定跳过")
        if alert.runModal() == .alertSecondButtonReturn {
            // SPEC-006 §3 / §6：记录跳过时所处步骤 + 写完成时间戳。
            Self.recordSkippedStep(step, into: .standard)
            appState.settings.onboardingCompletedAt = Date()
            onClose()
        }
    }

    /// 把「跳过引导」时所处的步骤并入 `kOnboardingSkippedSteps`（去重、升序、纯函数，可单测）。
    /// 直接走 UserDefaults：SPEC-006 §6 把该 key 列为独立数据契约，且不进 UserSettings 白名单结构体。
    static func recordSkippedStep(_ step: Int, into defaults: UserDefaults) {
        let existing = defaults.array(forKey: SettingsKey.onboardingSkippedSteps) as? [Int] ?? []
        let merged = Array(Set(existing).union([step])).sorted()
        defaults.set(merged, forKey: SettingsKey.onboardingSkippedSteps)
    }

    /// 判断 daemon 是否已安装：PATH 命中 `sieve`、任一已知路径存在、或 ipc.sock 存在皆视为已安装（SPEC-006 §4.4 / 场景 C）。
    /// 纯函数：注入候选路径 + socket 路径 + PATH 命中结果，便于单测。
    static func isDaemonInstalled(
        candidatePaths: [String],
        socketPath: String,
        pathLookupHit: Bool,
        fileExists: (String) -> Bool
    ) -> Bool {
        if pathLookupHit { return true }
        if candidatePaths.contains(where: fileExists) { return true }
        if fileExists(socketPath) { return true }
        return false
    }

    /// 生产环境探测：`which sieve` + 常见安装路径 + ipc.sock 存在性。
    private static func detectDaemonInstalled() -> Bool {
        let fm = FileManager.default
        let candidates = ["/usr/local/bin/sieve", "/opt/homebrew/bin/sieve"]
        let socket = (NSHomeDirectory() as NSString).appendingPathComponent(".sieve/ipc.sock")
        let whichHit: Bool = {
            let p = Process()
            p.launchPath = "/usr/bin/which"
            p.arguments = ["sieve"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do {
                try p.run()
                p.waitUntilExit()
                return p.terminationStatus == 0
            } catch {
                return false
            }
        }()
        return isDaemonInstalled(
            candidatePaths: candidates,
            socketPath: socket,
            pathLookupHit: whichHit,
            fileExists: { path in fm.fileExists(atPath: path) }
        )
    }

    private func runDoctor() {
        Task {
            do {
                let data = try await ipcClient.sendRequest(id: UUID().uuidString, method: "sieve.health")
                let dto = try JSONDecoder().decode(HealthResultDTO.self, from: data)
                await MainActor.run {
                    self.daemonNotInstalled = false
                    self.doctorResults = Self.checks(from: dto)
                }
            } catch {
                // 失联：先区分「未安装」（场景 C）与「装了但没起来」（场景 B）。
                let installed = Self.detectDaemonInstalled()
                await MainActor.run {
                    if installed {
                        self.daemonNotInstalled = false
                        // 装了但失联：展示占位条目，引导用户跑 sieve setup（场景 B）。
                        self.doctorResults = [
                            DoctorCheck(name: "ipc.sock 可连接", ok: false),
                            DoctorCheck(name: "daemon listener 已绑定", ok: false),
                            DoctorCheck(name: "audit.db 可访问", ok: false),
                            DoctorCheck(name: "规则引擎已加载", ok: false),
                            DoctorCheck(name: "client 握手成功", ok: false)
                        ]
                    } else {
                        // 未安装：展示专用提示 + 禁用继续（场景 C）。
                        self.daemonNotInstalled = true
                        self.doctorResults = []
                    }
                }
            }
        }
    }

    /// 基于 SPEC-005 §9.5 health 字段构造体检条目（ADR-026 后 listeners[] 优先）。
    static func checks(from dto: HealthResultDTO) -> [DoctorCheck] {
        let listeners = dto.effectiveListeners
        let listenerSummary = listeners
            .map { "\($0.port) [\($0.providerId)/\($0.`protocol`)]" }
            .joined(separator: ", ")
        let auditOK = dto.auditDb.schemaVersion >= 2
        let rulesOK = dto.rules.systemCount > 0
        let ipcOK = dto.ipc.connectedClients >= 1
        return [
            DoctorCheck(name: "ipc.sock 可连接（daemon v\(dto.daemonVersion) / 协议 \(dto.protocolVersion)）", ok: true),
            DoctorCheck(name: "daemon listener 已绑定：\(listenerSummary.isEmpty ? "无" : listenerSummary)", ok: !listeners.isEmpty),
            DoctorCheck(name: "audit.db schema v\(dto.auditDb.schemaVersion)（\(dto.auditDb.eventsTotal) 条事件）", ok: auditOK),
            DoctorCheck(name: "规则引擎已加载（系统 \(dto.rules.systemCount) / 用户 \(dto.rules.userCount)）", ok: rulesOK),
            DoctorCheck(name: "client 握手成功（在线 \(dto.ipc.connectedClients) 个）", ok: ipcOK)
        ]
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
