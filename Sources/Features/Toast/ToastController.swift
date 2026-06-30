import AppKit
import SwiftUI
import Combine

/// 状态栏右上角 Toast 单例。NSPanel 复用，5s 内同 kind 合并，最多 3 条。
@MainActor
public final class ToastController: NSObject, IPCToastAdapter {
    public static let shared = ToastController()

    private var stack: [ToastEntry] = []
    private var panels: [String: NSPanel] = [:]   // key = id
    private let appState = AppState.shared

    public func presentReconnect(_ kind: ReconnectKind) {
        let message: String
        switch kind {
        case .daemonRestarted:
            message = "Sieve daemon 已重启，状态可能丢失"
        case .reconnected:
            message = "已重新连接 daemon"
        }
        let entry = ToastEntry(
            id: UUID().uuidString,
            kind: .generic,  // 通用信息 toast（reconnect 通知）
            ruleId: "reconnect",
            severity: .low,
            direction: .inbound,
            summary: message,
            count: 1,
            firstSeenAt: Date(),
            lastUpdatedAt: Date(),
            auditEventId: nil
        )
        if stack.count < 3 {
            stack.append(entry)
            showPanel(for: entry)
            scheduleDismiss(for: entry)
        }
    }

    public func presentEvent(_ params: EventNotifyParams) {
        // StatusBarNotify wire（SPEC-005 §10.1）：title 即展示文案，rule_id 可空。
        let ruleId = params.ruleId ?? params.kind.rawValue
        // 合并：同 kind+rule_id 在 5s 内
        if let existingIdx = stack.firstIndex(where: { $0.kind == params.kind && $0.ruleId == ruleId && Date().timeIntervalSince($0.firstSeenAt) < 5 }) {
            stack[existingIdx].count += 1
            stack[existingIdx].lastUpdatedAt = Date()
            redrawPanel(stack[existingIdx])
            return
        }
        // 上限 3 条 → 转角标
        if stack.count >= 3 {
            // outboundRedacted/sequenceHit/loadFailed/reloaded 已由 AppState.recordHit
            // 按 redact/marked 计数；terminal/generic 不在该 action 子集，需在降级时显式补计。
            if params.kind == .hookTerminal || params.kind == .generic {
                appState.recordToastOverflow()
            }
            return
        }
        // direction/severity wire 不再携带，由 kind 派生展示语义（仅 Toast 图标用）。
        let direction: Direction = (params.kind == .outboundRedacted) ? .outbound : .inbound
        let severity: Severity = {
            switch params.kind {
            case .userRulesLoadFailed: return .high
            case .outboundRedacted, .hookTerminal, .sequenceHit: return .medium
            case .userRulesReloaded, .generic: return .low
            }
        }()
        let entry = ToastEntry(
            id: UUID().uuidString,
            kind: params.kind,
            ruleId: ruleId,
            severity: severity,
            direction: direction,
            summary: params.title,
            count: 1,
            firstSeenAt: Date(),
            lastUpdatedAt: Date(),
            auditEventId: nil
        )
        stack.append(entry)
        showPanel(for: entry)
        scheduleDismiss(for: entry)
    }

    private func showPanel(for entry: ToastEntry) {
        let panel = ToastPanel.make()
        let host = NSHostingController(rootView: ToastView(entry: entry, onTap: { [weak self] in self?.handleTap(entry) }, onDismiss: { [weak self] in self?.dismiss(id: entry.id) }))
        host.view.frame = NSRect(x: 0, y: 0, width: 340, height: 70)
        panel.contentViewController = host
        positionPanel(panel, index: stack.firstIndex(where: { $0.id == entry.id }) ?? 0)
        panel.makeKeyAndOrderFront(nil)
        panels[entry.id] = panel
    }

    private func redrawPanel(_ entry: ToastEntry) {
        guard let panel = panels[entry.id] else { return }
        let host = NSHostingController(rootView: ToastView(entry: entry, onTap: { [weak self] in self?.handleTap(entry) }, onDismiss: { [weak self] in self?.dismiss(id: entry.id) }))
        panel.contentViewController = host
    }

    private func positionPanel(_ panel: NSPanel, index: Int) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.maxX - 340 - 18
        let y = frame.maxY - 38 - 70 - CGFloat(index) * 78
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func scheduleDismiss(for entry: ToastEntry) {
        let duration = TimeInterval(appState.settings.toastDurationSeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.dismiss(id: entry.id)
        }
    }

    private func dismiss(id: String) {
        guard let panel = panels[id] else { return }
        // reduce-motion：跳过淡出，直接隐藏（保留关闭行为，移除动画）
        // 系统 flag 作为入参，由用户 reduceMotionOverride（system/always/never）决定最终值
        let reduceMotion = appState.settings.reduceMotionEnabled(
            systemReduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        if reduceMotion {
            panel.orderOut(nil)
            panels.removeValue(forKey: id)
            stack.removeAll { $0.id == id }
            for (i, e) in stack.enumerated() {
                if let p = panels[e.id] { positionPanel(p, index: i) }
            }
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                panel.orderOut(nil)
                self.panels.removeValue(forKey: id)
                self.stack.removeAll { $0.id == id }
                for (i, e) in self.stack.enumerated() {
                    if let p = self.panels[e.id] {
                        self.positionPanel(p, index: i)
                    }
                }
            }
        })
    }

    private func handleTap(_ entry: ToastEntry) {
        if let _ = entry.auditEventId {
            WindowManager.shared.openHistory()
        }
        dismiss(id: entry.id)
    }
}

public struct ToastEntry: Identifiable, Sendable {
    public let id: String
    public let kind: NotifyKind
    public let ruleId: String
    public let severity: Severity
    public let direction: Direction
    public let summary: String
    public var count: Int
    public let firstSeenAt: Date
    public var lastUpdatedAt: Date
    public let auditEventId: Int64?
}

public final class ToastPanel: NSPanel {
    public static func make() -> ToastPanel {
        let p = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 70),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        return p
    }
}

public struct ToastView: View {
    let entry: ToastEntry
    let onTap: () -> Void
    let onDismiss: () -> Void
    @State private var hovering: Bool = false

    public var body: some View {
        HStack(spacing: 10) {
            severityIcon.font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.summary).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    if entry.count > 1 {
                        Text("×\(entry.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(entry.ruleId).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
    }

    private var severityIcon: some View {
        Group {
            switch entry.severity {
            case .critical: Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            case .high: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .medium: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
            case .low: Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
            }
        }
    }
}
