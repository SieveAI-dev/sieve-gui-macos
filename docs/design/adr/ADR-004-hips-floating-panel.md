# ADR-004：HIPS 弹窗用 NSPanel + .floating + .canJoinAllSpaces + .fullScreenAuxiliary

> Status: Accepted
> Date: 2026-05-02
> Deciders: SieveAI
> Tags: ui, security

## Context

HIPS 弹窗是 Sieve GUI 的核心功能，其技术要求极为苛刻：

1. **P95 < 500ms**：从 IPC 收到 `request_decision` 到用户看到第一帧
2. **全屏应用上方可浮现**：用户在用全屏模式的 Claude Code 时（Terminal / IDE 全屏），弹窗必须能盖在上面
3. **抢占焦点**：弹窗弹出时必须夺取键盘焦点，让用户立即能用键盘操作（Return = 拒绝）
4. **不进 Dock**：整个 App 是 accessory app（LSUIElement = true），弹窗不能破坏这个约定
5. **多 Space 可见**：用户可能切 Space，弹窗应跟随（或至少在所有 Space 可见）

安全约束（CLAUDE.md 硬约束 3）：
- `recommendation` 缺失或 `confidence != high` 时，键盘 Return 默认走拒绝
- `allow_remember == false` 时禁止渲染 Remember checkbox

风险 OQ-G-01：在某些 macOS 版本和第三方 app 的全屏模式下，浮窗层级行为可能有差异，需要集成测试覆盖。

## Options Considered

### Option 1：NSPanel + .floating + .canJoinAllSpaces + .fullScreenAuxiliary（本方案）
- 优点：
  - `NSPanel` 是 AppKit 专为辅助面板设计的窗口子类，天然适合浮窗场景
  - `.floating` 层级（`NSWindow.Level.floating`）浮在所有普通窗口之上，低于 screensaver / cursor
  - `.canJoinAllSpaces` 让面板在所有 Mission Control Space 可见
  - `.fullScreenAuxiliary` 是关键标志：允许面板在全屏应用上方浮现（无此标志则被全屏 App 遮挡）
  - `NSApp.activate(ignoringOtherApps: true)` 抢焦点（macOS 14+ 有权限限制，见下）
  - NSPanel 实例可**复用**（预创建、隐藏态持有），只换 SwiftUI 根 View 的数据，避免每次重建窗口
- 缺点：
  - macOS 14+ `activate(ignoringOtherApps:)` 语义有变化（需要用 `NSApp.requestUserAttention` 或新 API 补强）
  - `.fullScreenAuxiliary` 在某些 Spaces 配置下偶发失效（已知 Apple bug，需要测试矩阵覆盖）
- 估计成本：低，有充分文档和先例（如系统内置的 Spotlight / Notification Center）

### Option 2：普通 NSWindow + .modalPanel 层级
- 优点：语义更明确（modal）
- 缺点：`.modalPanel` 会拦截所有用户输入到其他窗口（真正的系统模态），这与 PRD §5.2.2"用户仍可切到其他 App 阅读资料"冲突；不能与全屏 App 共存
- 估计成本：不符合功能需求

### Option 3：SwiftUI WindowGroup（覆盖全屏）
- 优点：声明式
- 缺点：SwiftUI 没有等价于 `.canJoinAllSpaces + .fullScreenAuxiliary` 的修饰符（macOS 13/14）；全屏行为不可控；与 ADR-001 中 NSPanel 需求不符
- 估计成本：不可行

### Option 4：通知中心（UNUserNotificationCenter）代替弹窗
- 优点：系统原生通知，不需要管窗口层级
- 缺点：通知无法承载 HIPS 弹窗的完整信息（地址对比 / 详情卡 / 倒计时 / 按钮）；PRD 明确要求 HIPS 是独立浮窗；通知可被用户 dismiss 且不保证 P95 < 500ms
- 估计成本：功能不满足

## Decision

选择 Option 1：**NSPanel + window.level = .floating + collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]**。

关键实现决策：

**NSPanel 复用**：`HipsPanelManager` 在 App 启动后预创建一个隐藏态 NSPanel（`isReleasedWhenClosed = false`），后续每次弹窗只更新根 SwiftUI HostingController 的 `rootView`，不重建 NSPanel 对象。这是达到 P95 < 500ms 的关键。

**抢焦点**：
```swift
NSApp.activate(ignoringOtherApps: true)
panel.makeKeyAndOrderFront(nil)
```
macOS 14+ 如果 `activate(ignoringOtherApps:)` 受限，补充 `NSApp.requestUserAttention(.critical)` + 系统提示音作为兜底。

**层级配置**：
```swift
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
panel.isMovableByWindowBackground = true
panel.hidesOnDeactivate = false
```

**防误点（0.4s 吞噬）**：Panel 显示后在 `HipsViewModel` 中记录 `visibleSince`，按钮 action 检查 `Date().timeIntervalSince(visibleSince) >= 0.4`，否则 noop。

**键盘默认**：HIPS SwiftUI View 的"拒绝"按钮设为 `.keyboardShortcut(.defaultAction)`（Return），在 `recommendation` 缺失或 `confidence != high` 时；"允许"按钮设 `.keyboardShortcut(.cancelAction)`（Escape）。

**OQ-G-01 风险说明**：`.fullScreenAuxiliary` 在部分 macOS 版本 + 第三方全屏 App（不走 `NSApplication.presentationOptions`）下有已知不一致行为。集成测试矩阵需覆盖：macOS 13/14/15 × 全屏 Terminal × Mission Control 多 Space。发现问题时的降级方案：触发系统通知 + 菜单栏角标 hold 状态作为最低保证。

## Consequences

**正面影响**：
- NSPanel 复用使首次显示后的每次弹窗几乎可瞬间完成（无窗口创建开销）
- `.fullScreenAuxiliary` + `.canJoinAllSpaces` 覆盖绝大多数用户工作场景
- 抢焦点保证键盘快捷键（Return = 拒绝）立即生效，不需要用户先点击弹窗

**引入的新约束**：
- `HipsPanelManager` 必须保证 NSPanel 在任何时刻只有一个实例（单例）
- Panel 的根 SwiftUI View 切换必须在主线程，且不能触发全量重建（用 `@Observable` 传引用，不传值）
- HIPS 弹窗关闭后 `rawJSON` 必须主动清零（data-model.md §3.1 HipsRequest 生命周期约束）
- macOS 14+ 的 `activate(ignoringOtherApps:)` 行为变化需要在 Week 5 集成测试中确认

**后续需要做的事**：
- SPEC-002 完成 NSPanel 配置的精确参数表
- 集成测试：全屏场景矩阵（macOS 13/14/15 × Terminal 全屏 × Space 切换）
- 如 `.fullScreenAuxiliary` 失效，记录降级路径到 SPEC-002 §6 错误与降级

## References

- ADR-003（窗口场景模型）：[`ADR-003-window-scene-model.md`](ADR-003-window-scene-model.md)
- [`SPEC-002-hips-popup-window.md`](../../specs/SPEC-002-hips-popup-window.md)
- 上游 [ADR-021（tri-state-decision-and-graylist）](../../external/upstream-references.md#adr-021tri-state-decision-and-graylist)
- [`docs/design/architecture.md`](../architecture.md) §2（HipsPanelManager）、§8（性能预算）
- PRD §5.2.2（窗口形态）、§5.2.7（防误点）、§8.1（P95 < 500ms 目标）
