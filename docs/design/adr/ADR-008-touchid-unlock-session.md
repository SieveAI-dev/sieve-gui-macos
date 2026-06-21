# ADR-008：LAContext + 5 分钟解锁会话覆盖所有敏感字段访问

> Status: Accepted
> Date: 2026-05-02
> Deciders: SieveAI
> Tags: security, ui

## Context

历史窗口和设置面板中存在若干敏感操作，需要用户认证后才能执行：

1. **开启"显示完整 evidence_meta"toggle**（历史窗口）
2. **点击"查看原始命中片段"**（历史窗口详情区）
3. **清空历史**（设置 Privacy 标签）
4. **其他需要二次确认的破坏性操作**

这些操作的共性：不能让随便触碰键盘的旁观者轻易查看或破坏历史数据。Touch ID 是 macOS 标准的用户认证机制（PRD §5.4.5）。

关键设计问题：
- 每次敏感操作都要求 Touch ID 会让用户感到烦躁（尤其是快速连续操作多条历史详情时）
- 但会话时间太长（如 30 分钟）则失去保护意义
- 用户取消或 Touch ID 失败时，系统如何降级？

## Options Considered

### Option 1：每次操作独立 Touch ID（无会话）
- 优点：最安全；每次访问都有明确授权
- 缺点：用户浏览历史时每展开一条都需要认证，体验极差；PRD §5.4.5 明确说"解锁 session 默认 5 分钟，期间不再重复要求"
- 估计成本：低，但体验不可接受

### Option 2：LAContext + 5 分钟解锁会话（本方案）
- 优点：
  - `LAContext.evaluatePolicy(.deviceOwnerAuthentication, ...)` 一次成功后，记录 `unlockedAt: Date`
  - 5 分钟内的后续敏感操作检查 `TouchIDSession.isValid`，不重复弹认证
  - 超时后 `AppState.unlockSession = nil`，下次访问重新认证
  - 5 分钟是 macOS Keychain 默认的缓存策略（用户对此时间窗口有心理预期）
  - 多窗口场景下同一会话共享（AppState 单例持有 `unlockSession`）
  - 失败 / 用户取消 → 回退到脱敏视图，写 gui.log，不写 audit.db
- 缺点：
  - 5 分钟内如果 Mac 被锁屏再解锁，`unlockSession` 仍然有效（未监听屏保事件）；可以通过监听 `NSWorkspace.screensaverDidStartNotification` 强制清除会话
- 估计成本：低，`LAContext` 标准 API

### Option 3：macOS Keychain 凭证缓存（让 Keychain 管 TTL）
- 优点：系统级 TTL 管理，最符合 macOS 惯例
- 缺点：
  - Keychain 缓存的 TTL 行为在不同 macOS 版本有差异，不可精确控制
  - GUI 没有要存在 Keychain 里的密钥材料，用 Keychain 只为认证感觉绕
- 估计成本：中，且行为不确定

### Option 4：macOS 用户密码（非 Touch ID，`LABiometryTypeNone` fallback）
- 优点：对没有 Touch ID 的 Mac（外接键盘）也有效
- 缺点：`LAContext.evaluatePolicy(.deviceOwnerAuthentication, ...)` 本身就会在 Touch ID 不可用时 fallback 到密码；Option 2 已经覆盖这个场景
- 估计成本：不需要额外决策，Option 2 自动处理

## Decision

选择 Option 2：**LAContext + 5 分钟解锁会话**，附加屏保/锁屏事件强制清除会话。

**实现**：

```swift
// TouchIDService.swift
final class TouchIDService {
    func requestUnlock() async -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = ""  // 禁止"使用密码"按钮（只允许 Touch ID）
        // 实际上仍 fallback 到密码，这里用 .biometrics 先尝试
        guard (try? await ctx.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: NSLocalizedString("touchid.reason", comment: "")
        )) == true else { return false }
        AppState.shared.unlockSession = TouchIDSession()
        return true
    }

    func forceExpire() {
        AppState.shared.unlockSession = nil
    }
}
```

```swift
// TouchIDSession（data-model.md §3.3）
final class TouchIDSession {
    let unlockedAt = Date()
    var expiresAt: Date { unlockedAt.addingTimeInterval(300) }  // 5 分钟
    var isValid: Bool { Date() < expiresAt }
}
```

**屏保锁屏强制清除**：

```swift
NotificationCenter.default.addObserver(
    forName: NSWorkspace.screensaverDidStartNotification,
    object: nil, queue: .main
) { _ in TouchIDService.shared.forceExpire() }
```

**失败回退**：认证失败 / 用户取消 → `TouchIDService.requestUnlock()` 返回 `false` → UI 保持脱敏视图 → gui.log 记录 `{scope: "touchid", level: "warn", msg: "unlock failed or cancelled"}`。不弹 UI 强制重试（不打扰用户）。

**不触发 UI 强制重试的理由**：PRD §5.4.5 明确"失败 / 用户取消 → 回退到脱敏态"。用户可以随时再次点击 toggle 触发认证。

## Consequences

**正面影响**：
- 5 分钟会话让用户浏览历史时不被反复打断
- `isValid` 检查纯内存，无额外 I/O
- Touch ID unavailable（无指纹传感器）时自动 fallback 到密码，覆盖所有 Mac 型号

**引入的新约束**：
- `AppState.unlockSession` 是单例，清除后所有窗口同时失效；如果用户同时打开历史和调试窗口，一次解锁两个都能访问敏感字段（可接受，同一用户会话）
- 解锁会话不持久化（进程退出即丢），重启 GUI 后需要重新认证
- 清空历史操作本身是破坏性的，即使在解锁会话内也需要弹 `NSAlert` 二次确认（PRD §5.3.3）；Touch ID 只是门槛，不替代确认对话框

**后续需要做的事**：
- 实现 `TouchIDService`，接入 AppState
- SPEC-004 §5 注明 Touch ID 触发入口的完整列表
- 测试：Touch ID unavailable Mac 上的 fallback 路径；屏保触发后会话失效验证

## References

- [`docs/design/data-model.md`](../data-model.md) §3.3（TouchIDSession 结构）
- [`SPEC-004-history-window.md`](../../specs/SPEC-004-history-window.md) §5（Touch ID 解锁）
- [`SPEC-003-settings-window.md`](../../specs/SPEC-003-settings-window.md) §3.3（清空历史 Touch ID）
- PRD §5.4.5（Touch ID 解锁规格）、§5.3.3（Privacy 标签清空历史）
