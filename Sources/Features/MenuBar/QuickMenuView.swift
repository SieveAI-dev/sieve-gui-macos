import SwiftUI

public struct QuickMenuView: View {
    @ObservedObject var appState: AppState
    let onOpenSettings: () -> Void
    let onOpenHistory: () -> Void
    let onOpenDebug: () -> Void
    let onPause: (Int) -> Void
    let onResume: () -> Void
    let onQuit: () -> Void

    @State private var pauseMinutes: Int = 5

    public init(
        appState: AppState,
        onOpenSettings: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void,
        onOpenDebug: @escaping () -> Void,
        onPause: @escaping (Int) -> Void,
        onResume: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.appState = appState
        self.onOpenSettings = onOpenSettings
        self.onOpenHistory = onOpenHistory
        self.onOpenDebug = onOpenDebug
        self.onPause = onPause
        self.onResume = onResume
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if case .disconnected(let reason) = appState.daemonStatus {
                disconnectedSection(reason: reason)
            } else {
                statusSection
                Divider()
                hitsSection
                Divider()
                pauseSection
            }

            Divider()
            footerSection
        }
        .frame(width: 320)
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.tint)
            Text("Sieve")
                .font(.headline)
            Spacer()
            if let v = appState.daemonVersion {
                Text("daemon \(v)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().frame(width: 8, height: 8).foregroundStyle(statusDotColor)
                Text(statusLabel)
                    .font(.subheadline)
            }
            Text("Preset: \(appState.preset.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var hitsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("最近命中")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if appState.recentHits.isEmpty {
                Text("暂无")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(appState.recentHits) { hit in
                    HStack(spacing: 6) {
                        DirectionBadge(hit.direction).font(.caption2)
                        Text(hit.ruleId)
                            .font(.caption)
                            .foregroundStyle(actionColor(hit.action))
                        Spacer()
                        Text(timeLabel(hit.occurredAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var pauseSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if appState.paused, let until = appState.pausedUntil {
                HStack {
                    Text("已暂停至 \(timeLabel(until))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("恢复", action: onResume)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            } else {
                HStack {
                    Picker("暂停", selection: $pauseMinutes) {
                        Text("5 分钟").tag(5)
                        Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    Button("暂停") { onPause(pauseMinutes) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            // 暂停期间始终可见（SPEC-001 §4.2 / PRD §5.1.3 硬约束：
            // 暂停态恰恰最该标注 Critical 仍生效）。两分支共用。
            Text("暂停期间 Critical 拦截仍然生效")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func disconnectedSection(reason: DaemonStatus.DisconnectReason) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("失联").font(.subheadline.weight(.semibold))
            }
            Text(disconnectReasonText(reason))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("打开 Onboarding 修复") { /* will be wired */ }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footerSection: some View {
        VStack(spacing: 0) {
            menuRow(symbol: "clock.arrow.circlepath", title: "历史…",  shortcut: "L", action: onOpenHistory)
            menuRow(symbol: "gearshape", title: "设置…",  shortcut: ",", action: onOpenSettings)
            menuRow(symbol: "ant.circle", title: "调试…",  shortcut: "D", action: onOpenDebug)
            Divider()
            menuRow(symbol: "power", title: "退出 Sieve GUI",  shortcut: "Q", action: onQuit)
        }
    }

    private func menuRow(symbol: String, title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: symbol).frame(width: 20)
                Text(title)
                Spacer()
                Text("⌘\(shortcut)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - helpers

    private var statusDotColor: Color {
        switch appState.daemonStatus {
        case .normal: return .green
        case .warning: return .yellow
        case .hold: return .orange
        case .paused: return .gray
        case .disconnected: return .red
        }
    }

    private var statusLabel: String {
        switch appState.daemonStatus {
        case .normal: return "正常"
        case .warning: return "有警告"
        case .hold: return "等待用户决策"
        case .paused: return "已暂停"
        case .disconnected: return "失联"
        }
    }

    private func actionColor(_ a: HitSummary.Action) -> Color {
        switch a {
        case .deny, .terminal: return .red
        case .redact, .marked: return .orange
        case .allow: return .secondary
        }
    }

    private func disconnectReasonText(_ r: DaemonStatus.DisconnectReason) -> String {
        switch r {
        case .socketMissing: return "找不到 ~/.sieve/ipc.sock。daemon 可能未启动。"
        case .heartbeatTimeout: return "30 秒未收到 daemon 消息。"
        case .versionMismatch: return "协议版本不兼容。请同步升级 daemon 与 GUI。"
        case .daemonShutdown: return "daemon 主动关闭了连接。"
        case .unknown: return "未知原因。"
        }
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
