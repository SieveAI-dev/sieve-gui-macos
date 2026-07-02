import SwiftUI

/// 敏感字段（钱包地址 / 私钥 / tool input / prompt）唯一渲染入口。
/// 红线：禁止用 `Text(secret)` 直接渲染。所有 evidence 类字段都应包到 `MaskedField` 中。
public struct MaskedField: View {
    public enum Style {
        case fullMask // 全部 ••••••••
        case prefix4Suffix4 // abcd••••wxyz
        case sessionTrunc // 取前 8 字符 + …
        case clearWhenUnlocked // 解锁后才显示原文
    }

    let value: String
    let style: Style
    let isUnlocked: Bool
    let monospaced: Bool
    let onCopy: (() -> Void)?

    @Environment(\.openURL) private var openURL

    public init(
        _ value: String,
        style: Style = .fullMask,
        isUnlocked: Bool = false,
        monospaced: Bool = true,
        onCopy: (() -> Void)? = nil
    ) {
        self.value = value
        self.style = style
        self.isUnlocked = isUnlocked
        self.monospaced = monospaced
        self.onCopy = onCopy
    }

    public var body: some View {
        Text(isUnlocked ? value : masked)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .foregroundStyle(isUnlocked ? Color.primary : Color.secondary)
            .accessibilityLabel(isUnlocked ? "已解锁敏感字段" : "脱敏字段")
    }

    private var masked: String {
        switch style {
        case .fullMask: return String(repeating: "•", count: 8)
        case .prefix4Suffix4:
            guard value.count > 8 else { return String(repeating: "•", count: 8) }
            let p = value.prefix(4)
            let s = value.suffix(4)
            return "\(p)••••\(s)"
        case .sessionTrunc:
            guard !value.isEmpty else { return "—" }
            return value.count > 8 ? "\(value.prefix(8))…" : value
        case .clearWhenUnlocked:
            return String(repeating: "•", count: 8)
        }
    }
}
