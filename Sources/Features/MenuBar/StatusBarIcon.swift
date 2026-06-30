import AppKit
import SwiftUI

/// 五状态菜单栏图标。SF Symbols 模板图，按 daemonStatus 切换。
public enum StatusBarIcon {
    public static func image(for status: DaemonStatus) -> NSImage {
        let presentation = StatusBarIconPresentation.resolve(for: status)
        var cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        if let color = paletteColor(for: presentation.tint) {
            cfg = cfg.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        }
        let img = NSImage(systemSymbolName: presentation.symbolName, accessibilityDescription: presentation.tooltip)
            ?? NSImage(named: NSImage.applicationIconName)
            ?? NSImage()
        let configured = img.withSymbolConfiguration(cfg) ?? img
        configured.isTemplate = presentation.tint == .template
        return configured
    }

    public static func accessibilityLabel(for status: DaemonStatus) -> String {
        StatusBarIconPresentation.resolve(for: status).tooltip
    }

    public static func accessibilityTitle(for status: DaemonStatus) -> String {
        StatusBarIconPresentation.resolve(for: status).accessibilityTitle
    }

    private static func paletteColor(for tint: StatusBarIconTint) -> NSColor? {
        switch tint {
        case .template:
            return nil
        case .warning:
            return .systemYellow
        case .danger:
            return .systemRed
        case .disabled:
            return .systemGray
        }
    }
}
