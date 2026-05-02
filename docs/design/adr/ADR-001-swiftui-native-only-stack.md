# ADR-001：Phase 1 锁定 SwiftUI native，不引入跨平台层

> Status: Accepted
> Date: 2026-05-02
> Deciders: doskey
> Tags: build, ui, infra

## Context

Sieve GUI 需要一个 macOS 原生客户端，负责 HIPS 弹窗、菜单栏、历史、设置、调试、Onboarding、Toast 等交互。技术栈选择在 Phase 1 决定后会深度渗透进所有模块，切换成本极高。

约束来源：

- 上游 daemon（ADR-012）已决定 Phase 1 GUI 走独立 git 仓库 `sieve-gui-macos`，并规定 Phase 1 只做 macOS，不为跨平台预留抽象层（PRD §1.3 §9 条 9 和 11）。
- 项目由 doskey 单人维护，团队规模决定可投入的框架学习成本有限。
- HIPS 弹窗 P95 显示延迟须 < 500ms（PRD §8.1），webview 渲染引入额外层的延迟风险高。
- 第三方依赖白名单限定为 `SQLite.swift` + `Sparkle`，任何额外依赖都需要显式放行。

## Options Considered

### Option 1：SwiftUI（macOS 13+）+ AppKit 补丁（NSPanel 等）
- 优点：macOS 一等公民，与系统 API 零摩擦；`NSStatusItem` / `NSPanel` / `LAContext` / `SMAppService` 可直接调用；`Network.framework` / Combine 生态无缝集成；审计 entitlement 最简单；Apple notarization 流程最顺
- 优点：`.xcstrings` String Catalogs（macOS 14+）无需额外工具；SF Symbols 直用
- 缺点：macOS only，Phase 2 如需跨平台要重写；macOS 13/14 API 差异需要 `@available` 检查
- 估计成本：框架熟悉度已具备，额外成本近 0

### Option 2：Tauri（Rust + WebView）
- 优点：前端生态；可复用 daemon 的 Rust 代码
- 缺点：webview 层引入 layout / rendering 延迟，难以保证 P95 < 500ms；NSPanel `.floating` + `.canJoinAllSpaces` 需要 Tauri 插件或自定义 native 桥；entitlement 审计复杂（webview sandbox 规则）；与 Sparkle / LAContext 集成非 native；与 PRD §9 条 9 明确冲突
- 估计成本：学习成本 + 性能风险 + IPC bridging 成本显著

### Option 3：Catalyst（iOS/iPadOS App 移植到 macOS）
- 优点：官方方案，SwiftUI 同一份代码
- 缺点：Catalyst App 在菜单栏 accessory app 场景有大量限制（`LSUIElement = true` + `NSStatusItem` 不完整）；与 PRD §9 条 9 "Catalyst = 不做"明确冲突
- 估计成本：与目标场景不符，排除

### Option 4：Electron
- 优点：开发者熟悉度高；跨平台
- 缺点：内存 > 80MB 几乎不可避免（Node.js + Chromium）；PRD §8.1 内存目标 < 80MB；启动时间难以控制；与 PRD §9 条 11 明确冲突；`hardened runtime` + notarization 在 Electron 更复杂
- 估计成本：与约束直接冲突，排除

## Decision

选择 Option 1：**SwiftUI（macOS 13+）+ AppKit 补丁**。这是上游 ADR-012 在 GUI 仓库内的延伸实现。

第三方依赖白名单严格限定：
- `SQLite.swift`：audit.db 只读访问
- `Sparkle`：自动更新（EdDSA 签名）

其他任何第三方依赖一律 reject。RxSwift / Objective-C++ / SwiftCrossUI / TCA 等同样排除。

## Consequences

**正面影响**：
- 与 macOS 系统 API 零摩擦，NSPanel / NSStatusItem / LAContext / SMAppService 直接调用
- entitlement 集合最小（网络客户端可设为 false，Sparkle 例外单独处理）
- hardened runtime + notarization 流程最顺畅
- `@Observable`（macOS 14+）+ Combine 状态管理无需额外依赖

**引入的新约束**：
- Phase 1 代码无法直接复用到 Linux/Windows；Phase 2 扩平台需要重写或分叉
- AppKit 补丁（NSPanel 浮窗、NSStatusItem）不能通过 SwiftUI preview 完整测试，需要真机/模拟器跑
- macOS 13 / 14 API 差异需要在每个使用 `@Observable`、`.menuBarExtra`（macOS 13 限制见 ADR-003）的地方做 `@available` 检查

**后续需要做的事**：
- ADR-003 明确多 Window scene 模型的兼容性策略
- CI 构建目标 macOS 13 deployment target，禁止 14-only API 在主路径未经 `@available` 保护
- CLAUDE.md 编码规范中已明确：Swift 5.9+，`-warnings-as-errors`，所有 IPC 消息走 `Codable`，这些约束与 SwiftUI native 选型完全对齐，不需要任何 shim 层

**未决事项（OQ）**：

| 编号 | 问题 | 当前选项 | 截止决策 |
|------|------|---------|---------|
| OQ-A-01 | Phase 2 如果需要 Linux GUI，是否考虑 Swift on Linux + GTK？还是直接 Rust webview？ | 不预设，等 Phase 2 真实需求 | v1.0 GA 后评估 |

## References

- 上游 [ADR-012（native-gui-app-phase1）](../../external/upstream-references.md#adr-012native-gui-app-phase1)
- PRD §1.3（不是什么）：[`docs/requirements/sieve-gui-macos-prd-v1.0.md`](../../requirements/sieve-gui-macos-prd-v1.0.md)
- PRD §9 条 9、11（硬约束）
- [`CLAUDE.md`](../../../CLAUDE.md) 技术栈硬约束
