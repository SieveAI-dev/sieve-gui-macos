import Foundation

/// HIPS footer 键盘归属的唯一规则（P0-2/P0-3，纯函数，矩阵测试锚定防回归）。
///
/// 硬规则：Return（`.defaultAction`）在任何 {mainActionLocked × phase × swapped ×
/// merged × canAllowAll} 组合下只绑定「拒绝/拒绝全部」；允许类按钮永不挂任何
/// keyboardShortcut。键盘因此无法触发允许，red 阶段的 ⌘+Click 门不存在键盘旁路。
/// swapped 布局只改视觉位置，不改快捷键归属。
public enum HipsFooterPolicy {
    public enum ReturnKeyOwner: Equatable {
        case deny
    }

    /// footer 按钮的语义角色。允许类含单 issue「允许」/merged「全部允许」/「仅允许非 Critical」；
    /// 拒绝类含「拒绝」/「拒绝全部」。
    public enum ButtonRole: Sendable, Equatable {
        case allow
        case deny
    }

    /// 给定按钮角色，它是否应挂 Return（`.defaultAction`）快捷键。
    /// **View 必须用本函数派生每个 footer 按钮的 keyboardShortcut**，而非手写——
    /// 使「允许类永不获 Return、Return 恒绑拒绝」从注释约定升级为策略驱动 + 矩阵测试编译期锚定
    /// （P0-2/P0-3 防回归；此前 View 手写挂接不消费策略，误加快捷键矩阵测试抓不到）。
    public static func bindsReturnKey(role: ButtonRole) -> Bool {
        role == .deny
    }

    public struct FooterState: Sendable, Equatable {
        public let mainActionLocked: Bool
        public let phaseRequiresCmdClick: Bool
        public let swappedLayout: Bool
        public let merged: Bool
        public let canAllowAll: Bool

        public init(
            mainActionLocked: Bool,
            phaseRequiresCmdClick: Bool,
            swappedLayout: Bool,
            merged: Bool = false,
            canAllowAll: Bool = false
        ) {
            self.mainActionLocked = mainActionLocked
            self.phaseRequiresCmdClick = phaseRequiresCmdClick
            self.swappedLayout = swappedLayout
            self.merged = merged
            self.canAllowAll = canAllowAll
        }
    }

    /// Return 键归属：恒 deny，不随任何状态变化（红线）。
    public static func returnKeyOwner(_: FooterState) -> ReturnKeyOwner {
        .deny
    }

    /// 允许类按钮是否可挂 keyboardShortcut：恒否（红线）。
    public static func allowMayHaveKeyboardShortcut(_: FooterState) -> Bool {
        false
    }

    /// 视觉主按钮（borderedProminent）是否在允许侧：
    /// 仅「高置信 allow 推荐 + 非 red 阶段 + 非换位 + 非 merged」时成立。
    /// 注意视觉主选 ≠ Return 归属——即使允许侧是视觉主选，Return 仍在拒绝侧。
    public static func allowIsProminent(_ state: FooterState) -> Bool {
        !state.merged
            && !state.mainActionLocked
            && !state.phaseRequiresCmdClick
            && !state.swappedLayout
    }
}

/// red 阶段「允许」动作的放行门（P0-3）：必须是带 ⌘ 的鼠标点击事件；
/// 键盘触发（无论经何种快捷键进入）一律不放行。
public enum CmdClickGate {
    public static func permitsAllow(
        phaseRequiresCmdClick: Bool,
        eventIsMouseClick: Bool,
        hasCommandModifier: Bool
    ) -> Bool {
        guard phaseRequiresCmdClick else { return true }
        return eventIsMouseClick && hasCommandModifier
    }
}
