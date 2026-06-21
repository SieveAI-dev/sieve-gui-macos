# ADR-007：跟随系统 / 强制 light / 强制 dark 三档主题

> Status: Accepted
> Date: 2026-05-02
> Deciders: SieveAI
> Tags: ui

## Context

Sieve GUI 的设置面板提供外观选项，允许用户控制应用的 dark/light 模式（PRD §5.3.1 / data-model.md kAppearance key）。

核心设计约束：
1. **HIPS 弹窗在 dark mode 下必须保持高对比度**：critical 配色（红/橙）不能因为 dark mode 失去可读性（PRD §7.4）
2. **与系统 reduce-motion 联动**：所有动效尊重 `accessibilityReduceMotion`（PRD §7.3）
3. 三档：`system`（跟随系统）/ `light`（强制 light）/ `dark`（强制 dark）
4. macOS 13 deployment target，`NSAppearance` 是最低公约数 API

与 ADR-006 的交叉：语言和主题都存在 UserDefaults，都需要在设置面板生效后即时刷新所有窗口，不重启。

## Options Considered

### Option 1：NSAppearance 注入到 NSWindow + SwiftUI .preferredColorScheme（本方案）
- 优点：
  - `NSWindow.appearance = NSAppearance(named: .darkAqua)` / `.aqua` 是控制单 App 外观的官方方式
  - SwiftUI View 的 `.preferredColorScheme(.dark / .light)` modifier 可在 View 树层面覆盖，与 NSWindow 外观联动
  - `system` 档：设置 `NSWindow.appearance = nil`（继承系统值）
  - 应用到所有窗口：`WindowManager` 的 `applyTheme` 方法遍历所有打开的 NSWindow，统一设置 `.appearance`
  - HIPS NSPanel 预创建时 appearance 已绑定，弹出前刷新一次即可
  - **reduce-motion**：通过 `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` 读取系统设置，结合 `kReduceMotionOverride` UserDefaults 给出三态（system / on / off）
- 缺点：新打开的窗口需要在创建时从 AppState 读取当前主题并应用；WindowManager 的 `open(window:)` 方法中需要加一行 `applyTheme`
- 估计成本：低，标准 API

### Option 2：仅用 SwiftUI .preferredColorScheme 在根 View 层面控制
- 优点：纯 SwiftUI，无需操作 NSWindow
- 缺点：
  - `.preferredColorScheme` 作用于 View 树，但 NSPanel 的 vibrancy material（`NSVisualEffectView`）不跟随 SwiftUI preference，需要额外桥接
  - AppKit 组件（NSPopover / NSPanel 的非 SwiftUI 部分）仍然跟随系统外观，出现混用情况
- 估计成本：中，且视觉一致性有风险

### Option 3：UserDefaults `AppleInterfaceTheme` / `NSAppearanceName` 覆盖
- 优点：全局影响，无需逐窗口设置
- 缺点：这是修改系统级偏好，会影响整个用户会话中所有 App；不可接受
- 估计成本：不可行

### Option 4：忽略用户主题偏好，完全跟随系统
- 优点：零代码
- 缺点：PRD §5.3.1 明确要求三档 Picker；不满足需求
- 估计成本：需求不满足

## Decision

选择 Option 1：**NSAppearance 注入到所有 NSWindow + SwiftUI .preferredColorScheme 根 View modifier + reduce-motion 三态覆盖**。

**主题应用流程**：

```swift
// ThemeService.swift
enum AppearanceMode: String, CaseIterable {
    case system, light, dark
}

final class ThemeService {
    func apply(_ mode: AppearanceMode) {
        let appearance: NSAppearance? = switch mode {
            case .system: nil
            case .light:  NSAppearance(named: .aqua)
            case .dark:   NSAppearance(named: .darkAqua)
        }
        // 应用到所有已打开窗口
        NSApplication.shared.windows.forEach { $0.appearance = appearance }
        // 预创建的 NSPanel 也更新
        HipsPanelManager.shared.panel?.appearance = appearance
    }
}
```

SwiftUI 根 View 上 `.preferredColorScheme(AppState.shared.colorScheme)` 保证 SwiftUI 层和 AppKit 层一致。

**HIPS 弹窗 critical 配色保证**：

不论外观档位，HIPS 弹窗的 critical / high 颜色使用 semantic color（`Color(.systemRed)` / `Color(.systemOrange)`），这些 semantic token 在 dark 下有 Apple 官方对应值，自动保持对比度。background 使用 vibrancy material（`NSVisualEffectView`），不硬编码颜色。

**reduce-motion 三态**：

```swift
var effectiveReduceMotion: Bool {
    switch kReduceMotionOverride {
    case "on":     return true
    case "off":    return false
    default:       return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
```

所有动效（倒计时闪烁 / 窗口滑入 / 状态切换）在 `effectiveReduceMotion == true` 时替换为淡入淡出或无动效。

## Consequences

**正面影响**：
- 跟随系统档让用户不需要在 Sieve GUI 里额外设置
- HIPS 弹窗 critical 配色通过 semantic color 自动适配，无需维护 dark mode 专属颜色表
- reduce-motion 联动覆盖了辅助功能用户（PRD §7.5 A11y 要求）

**引入的新约束**：
- `WindowManager` 每次打开新窗口时必须调用 `ThemeService.apply(current)`，否则新窗口会短暂使用系统默认
- 禁止在任何 SwiftUI View 中硬编码颜色值（如 `Color(red: 1, green: 0, blue: 0)`）；必须使用 semantic color 或设计系统的 Color 常量
- HIPS 弹窗预创建时（App 启动）就要 apply 当前 appearance，不能等到弹出时才设

**后续需要做的事**：
- 创建 `ThemeService` 并接入 AppState
- 实现 `ReduceMotionEnvironmentKey`，在所有有动效的 View 中 `@Environment` 读取
- 视觉测试：在 dark 模式下截图 HIPS 弹窗 critical 配色，人工确认对比度 ≥ WCAG AA

## References

- [`docs/design/data-model.md`](../data-model.md) §1（kAppearance / kReduceMotionOverride UserDefaults key）
- [`SPEC-002-hips-popup-window.md`](../../specs/SPEC-002-hips-popup-window.md)（critical 配色规格）
- [`SPEC-003-settings-window.md`](../../specs/SPEC-003-settings-window.md) §4.1（General 标签主题 Picker）
- PRD §5.3.1（主题控件）、§7.3（动效规范）、§7.4（主题）、§7.5（A11y）
