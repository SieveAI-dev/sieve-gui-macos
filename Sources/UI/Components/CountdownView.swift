import SwiftUI

public struct CountdownView: View {
    let remainingSeconds: Int
    let totalSeconds: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(remainingSeconds: Int, totalSeconds: Int) {
        self.remainingSeconds = remainingSeconds
        self.totalSeconds = totalSeconds
    }

    public var body: some View {
        HStack(spacing: 8) {
            Text("\(remainingSeconds)s")
                .font(.system(.body, design: .monospaced).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(color)
                // Phase3（red）闪烁动画：reduce-motion=true 时禁用，保留颜色切换
                .opacity(shouldFlash ? flashOpacity : 1.0)
                .animation(
                    reduceMotion ? nil : (phase == .red ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : nil),
                    value: flashOpacity
                )

            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(color)
                .frame(maxWidth: .infinity)
                // 进度条颜色切换不受 reduce-motion 影响（信息量不能丢）
        }
    }

    // 是否处于红色闪烁阶段
    private var shouldFlash: Bool { phase == .red && !reduceMotion }
    // 闪烁时的不透明度驱动（通过 animation modifier 触发）
    private var flashOpacity: Double { phase == .red ? 0.4 : 1.0 }

    public var phase: HipsPhase {
        HipsPhase.resolve(
            remaining: Double(remainingSeconds),
            total: Double(totalSeconds)
        )
    }

    private var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return min(1, max(0, Double(remainingSeconds) / Double(totalSeconds)))
    }

    private var color: Color {
        switch phase {
        case .blue: return .accentColor
        case .orange: return .orange
        case .red: return .red
        }
    }
}

public struct DisconnectedBanner: View {
    let reason: DaemonStatus.DisconnectReason
    let onAction: (() -> Void)?

    public init(reason: DaemonStatus.DisconnectReason, onAction: (() -> Void)? = nil) {
        self.reason = reason
        self.onAction = onAction
    }

    public var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sieve 与 daemon 失联")
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let onAction {
                Button("重新连接", action: onAction)
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.08))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.red.opacity(0.3)), alignment: .bottom)
    }

    private var detail: String {
        switch reason {
        case .socketMissing: return "找不到 ~/.sieve/ipc.sock，daemon 可能未启动。"
        case .connectionRefused: return "~/.sieve/ipc.sock 存在，但 daemon 拒绝连接，请重启 daemon。"
        case .heartbeatTimeout: return "30 秒未收到 daemon 消息。"
        case .versionMismatch: return "协议版本不兼容，请同步升级 daemon 与 GUI。"
        case .daemonShutdown: return "daemon 主动关闭了连接。"
        case .unknown: return "未知原因。"
        }
    }
}
