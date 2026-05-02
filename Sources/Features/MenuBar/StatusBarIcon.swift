import AppKit
import SwiftUI

/// 五状态菜单栏图标。SF Symbols 模板图，按 daemonStatus 切换。
public enum StatusBarIcon {
    public static func image(for status: DaemonStatus) -> NSImage {
        let symbolName: String
        switch status {
        case .normal: symbolName = "shield.lefthalf.filled"
        case .warning: symbolName = "shield.lefthalf.filled.badge.checkmark"
        case .hold: symbolName = "shield.lefthalf.filled.trianglebadge.exclamationmark"
        case .paused: symbolName = "pause.circle"
        case .disconnected: symbolName = "shield.slash"
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel(for: status))
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
        img.isTemplate = true
        return img.withSymbolConfiguration(cfg) ?? img
    }

    public static func accessibilityLabel(for status: DaemonStatus) -> String {
        switch status {
        case .normal: return "Sieve 正常"
        case .warning: return "Sieve 有警告"
        case .hold: return "Sieve 正在等待用户决策"
        case .paused: return "Sieve 已暂停"
        case .disconnected: return "Sieve 失联"
        }
    }
}
