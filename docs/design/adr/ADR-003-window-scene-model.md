# ADR-003：LSUIElement = true，多 SwiftUI Window scene + 浮窗 NSPanel

> Status: Accepted
> Date: 2026-05-02
> Deciders: doskey
> Tags: ui, infra

## Context

Sieve GUI 是一个 accessory app（无 Dock 图标），需要同时管理：

1. **菜单栏**：常驻 `NSStatusItem` + Quick Menu popover
2. **HIPS 弹窗**：抢占焦点的浮窗，全程置顶，见 ADR-004
3. **Settings / History / Debug / Onboarding 窗口**：用户主动打开的标准窗口，互相独立，可同时存在

核心约束：
- `LSUIElement = true`：不进 Dock，无主菜单条（`NSApp.mainMenu` 为 nil）；这是 PRD §1.1 + CLAUDE.md 进程模型的硬约束
- macOS 13 支持要求（deployment target）
- 窗口之间独立开关（非模态，Onboarding 除外）
- 每种窗口最多一个实例（Settings / History / Debug 单例；Onboarding 在引导期间模态）

## Options Considered

### Option 1：SwiftUI `.menuBarExtra` scene + 多 `WindowGroup`
- 优点：macOS 13+ 原生 SwiftUI 方式；`.menuBarExtra` 内置菜单栏逻辑；`WindowGroup` 自动管理窗口生命周期；SwiftUI `@Environment(\.openWindow)` 可跨 scene 打开窗口
- 缺点：`.menuBarExtra` 的 popover 样式在 macOS 13 有渲染限制（内容高度动态化有 bug，macOS 14 修复）；HIPS 浮窗需要混用 AppKit `NSPanel`，与 SwiftUI scene 模型混搭时生命周期管理复杂；Onboarding 的"模态覆盖所有窗口"行为在多 scene 架构下实现代价较高
- 估计成本：中等，但 macOS 13 的 `.menuBarExtra` 限制需要 workaround

### Option 2：纯 AppKit `NSApplication` + `NSStatusItem`，SwiftUI 作为 view 层（本方案）
- 优点：`NSStatusItem` + `NSStatusBarButton` 完全可控；菜单栏 Quick Menu 用 `NSPopover` 包 SwiftUI `View`，兼容 macOS 13；各窗口用 `NSWindowController` 持有，实例单例化简单；HIPS `NSPanel` 与 Settings `NSWindow` 生命周期清晰分离；Onboarding 用 `.beginSheet` 或 `makeKeyAndOrderFront` 配合 `NSApplication.runModal` 实现真正模态
- 缺点：比纯 SwiftUI scene 多一层 AppKit 胶水代码（AppDelegate + WindowManager）；不能直接用 `@Environment(\.openWindow)`，需要自己实现 WindowManager 单例
- 估计成本：中等，但可预期、可控

### Option 3：SwiftUI `@main App` + 手动管理 `NSWindow`（混合模式）
- 优点：SwiftUI App 生命周期 + 手动 AppKit 窗口
- 缺点：SwiftUI App 生命周期会尝试自动管理窗口，和 `LSUIElement = true` 的 accessory app 行为有微妙冲突（如自动显示的欢迎窗口）；需要更多 hack 才能让 SwiftUI App 在 `LSUIElement` 模式下干净运行
- 估计成本：高，陷阱多，不推荐

### Option 4：纯 AppKit，不用 SwiftUI
- 优点：完全控制
- 缺点：ADR-001 已决定 SwiftUI 为主要 UI 框架；纯 AppKit 开发量过大，与 Phase 1 周期不符
- 估计成本：不可接受

## Decision

选择 Option 2：**AppDelegate + NSStatusItem + 多 SwiftUI Window scene（手动管理）**。

具体方案：

**进程模型**：`LSUIElement = true`（Info.plist），`NSApp.setActivationPolicy(.accessory)`，不进 Dock，无主菜单条。

**菜单栏**：`AppDelegate` 在 `applicationDidFinishLaunching` 中创建 `NSStatusItem`，持有到 AppDelegate 生命周期结束。Quick Menu 用 `NSPopover` 包住 SwiftUI `MenuBarView`，点击 StatusItem 按钮 toggle。

**Settings / History / Debug 窗口**：`WindowManager` 单例为每种窗口维护一个可选 `NSWindowController?`，打开时若为 nil 则创建，否则 `makeKeyAndOrderFront`（单例化）。每个窗口托管 SwiftUI `View` 作为根内容（`NSHostingController`）。`Window` scene 用 SwiftUI 的同名修饰符声明，但不依赖 SwiftUI 自动显示机制。

**Onboarding 窗口**：首次启动时用 `NSApplication.runModalSession` 或 `presentAsModalWindow` 实现覆盖模态；完成后 `stopModal`。

**为何不用 `.menuBarExtra`**：macOS 13 上 `.menuBarExtra` 的 popover 高度动态化有已知 bug（高度超过某值会截断），且与 `LSUIElement` 的 accessory 模式的交互有未文档化的限制。macOS 13 是 deployment target，需要兼容。

## Consequences

**正面影响**：
- 窗口生命周期完全可控，单例化逻辑简单
- HIPS `NSPanel` 与其他窗口完全解耦（见 ADR-004）
- macOS 13 / 14 / 15 行为一致，无需 `@available` 绕行

**引入的新约束**：
- 不能直接使用 SwiftUI `@Environment(\.openWindow)` 跨 scene 打开窗口；WindowManager 单例是唯一入口
- AppDelegate 必须保持轻量（只初始化，业务逻辑放 Service/Manager）；防止 AppDelegate 膨胀
- 每个 Window 的 SwiftUI 根 View 对应一个 ViewModel，ViewModel 生命周期与 NSWindowController 一致（窗口关闭时 ViewModel 释放，`weak` 持有避免泄漏）

**后续需要做的事**：
- 实现 `WindowManager` 类，暴露 `open(Settings)` / `open(History)` 等方法
- Onboarding 模态的键盘焦点链需要额外测试（VoiceOver + Tab 导航）
- 升级到 macOS 14 专用 API（如 `.menuBarExtra` 或 `@Observable`）时，评估是否可以替换部分 AppKit 胶水

## References

- ADR-001（SwiftUI native 选型）：[`ADR-001-swiftui-native-only-stack.md`](ADR-001-swiftui-native-only-stack.md)
- ADR-004（HIPS 浮窗）：[`ADR-004-hips-floating-panel.md`](ADR-004-hips-floating-panel.md)
- [`docs/design/architecture.md`](../architecture.md) §2（进程内结构）
- PRD §3（信息架构总览）、§5.2.2（HIPS 窗口形态）、§5.6.3（Onboarding 模态行为）
- SPEC-001（菜单栏）：[`docs/specs/SPEC-001-menu-bar-and-quick-menu.md`](../../specs/SPEC-001-menu-bar-and-quick-menu.md)
