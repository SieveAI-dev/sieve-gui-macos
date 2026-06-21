# ADR-006：用 macOS 14+ String Catalogs（Localizable.xcstrings），zh/en 双语

> Status: Accepted
> Date: 2026-05-02
> Deciders: SieveAI
> Tags: ui, infra

## Context

Sieve GUI 面向中文为主的用户群（PRD §7.2），同时需要英文支持（工具链术语 / 海外用户 / 调试场景）。国际化需求：

1. **双语**：v1 仅 zh-Hans / en；v2.1 评估其他语言
2. **运行时切语言**：设置面板有语言 Picker（跟随系统 / 中文 / English），切换后**不重启**即生效（PRD §5.3.1）
3. **rule title 不由 GUI 维护**：daemon 推送的 `request_decision.params.title` 和 `recommendation.reason` 已经是本地化后的字符串，GUI 直接展示，不走 GUI 的本地化管线
4. macOS 14+ String Catalogs（`.xcstrings`）是 Apple 推荐的现代国际化方案，Xcode 15+ 原生支持

约束：
- CLAUDE.md 编码规范：用户可见文案一律走 String Catalogs（`Localizable.xcstrings`）
- deployment target macOS 13，需要确认运行时兼容性

## Options Considered

### Option 1：传统 .strings 文件（Localizable.strings + Localizable.stringsdict）
- 优点：macOS 所有版本支持；工具链成熟；不依赖 Xcode 15+
- 缺点：
  - 没有类型安全的 key 系统（字符串 key 拼写错误运行时才暴露）
  - 多语言文件分散（`zh-Hans.lproj/Localizable.strings` + `en.lproj/Localizable.strings`），diff 困难
  - 不支持在 Xcode 中的可视化翻译工作流
  - 运行时切语言需要自己实现（`Bundle` 切换 + `SwiftUI` 刷新），传统 `.strings` 不内建此功能
- 估计成本：运行时切语言的实现成本高（需要自定义 `LocalizedStringKey` 路由）

### Option 2：macOS 14+ String Catalogs（.xcstrings）（本方案）
- 优点：
  - 单文件 JSON 格式（`Localizable.xcstrings`），所有语言版本合并，diff 友好
  - Xcode 15+ 可视化翻译界面，缺失翻译有警告
  - `String(localized:)` / `LocalizedStringKey` 同样适用，使用方式与 `.strings` 一致
  - Xcode 在编译期自动从 SwiftUI 源码提取 key，减少遗漏
  - **运行时切语言**：通过替换 `Bundle.main` 的 locale（`Bundle(path:)` + `UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")`），配合自定义 `EnvironmentKey` 传递当前 locale，在不重启的情况下驱动 SwiftUI 重新渲染
  - `.xcstrings` 文件格式向后兼容 `.strings`（Xcode 编译时生成 `.strings` 产物）；运行时使用 `Bundle` API，macOS 13 完全兼容
- 缺点：
  - 运行时切语言不是 `.xcstrings` 原生特性，仍需 `Bundle` swap trick
  - Xcode 15+ 才有可视化编辑器；Xcode 14 只能手编 JSON（但 deployment target 不影响运行时）
- 估计成本：低，使用方式与传统 `.strings` 几乎相同

### Option 3：第三方 i18n 库（如 BartyCrouch / SwiftGen）
- 优点：代码生成类型安全 key
- 缺点：额外依赖（白名单外）；与 String Catalogs 相比收益有限；ADR-001 约束
- 估计成本：违反依赖白名单，排除

## Decision

选择 Option 2：**String Catalogs（Localizable.xcstrings）+ 自定义 Bundle swap 实现运行时切语言**。

**运行时切语言实现方案**：

```swift
// LanguageService.swift
@Observable final class LanguageService {
    var currentLocale: Locale = .current

    func switchLanguage(to identifier: String?) {
        if let id = identifier {
            UserDefaults.standard.set([id], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        // 触发 SwiftUI 环境刷新（重建根 View 的 locale）
        NotificationCenter.default.post(name: .languageDidChange, object: nil)
    }
}
```

SwiftUI 根视图监听 `languageDidChange`，刷新 `\.locale` 环境值，触发所有 `LocalizedStringKey` 重新解析。NSPanel / NSPopover 包含的 SwiftUI View 通过同样机制刷新。

**分工**：
- GUI 自身文案（按钮 label、窗口标题、提示文字、状态描述）→ `Localizable.xcstrings`
- daemon 推送的字符串（`rule_id` title、`recommendation.reason`）→ daemon 侧本地化，GUI 直接显示，不走 xcstrings
- 调试日志（gui.log）→ 硬编码英文，不走 xcstrings

**键命名规范**：
- 格式：`<模块>.<控件>.<含义>`，全小写，点分隔。例：`hips.button.deny`、`settings.general.theme.label`
- 复数形式走 `.stringsdict`（`.xcstrings` 内建支持 plural rules）

## Consequences

**正面影响**：
- 所有文案集中在一个文件，翻译进度一目了然
- Xcode 编译期提取 key，遗漏翻译有警告
- 运行时切语言无需重启，提升用户体验

**引入的新约束**：
- 所有用户可见文案必须走 `LocalizedStringKey` 或 `String(localized:)`，禁止硬编码中文字面量（CLAUDE.md 约束）
- daemon 推送的文案（title / reason）不经过 GUI i18n 管线——意味着 GUI 的语言 Picker 只影响 GUI 自身文案，rule title 的语言由 daemon 端配置决定（这一差异需要在设置面板 UI 上标注说明）
- 在每个 NSPanel / NSPopover 的 SwiftUI root view 中确保 `.environment(\.locale, ...)` 正确传递
- v2.1 新增语言时只需在 `.xcstrings` 中增加 locale 条目，不改代码

**后续需要做的事**：
- 创建 `Localizable.xcstrings`，初始化 zh-Hans / en 两套 locale
- 实现 `LanguageService`，连接到 AppState 和设置面板 Picker
- 在 SPEC-003（设置窗口）§4.1 标注"语言切换只影响 GUI 文案"的 UI 提示文案

## References

- [`SPEC-003-settings-window.md`](../../specs/SPEC-003-settings-window.md) §4.1（General 标签语言 Picker）
- PRD §5.3.1（语言设置控件）、§7.2（文案语调）、§7.6（国际化）
- [`docs/design/data-model.md`](../data-model.md) §1（kLanguage UserDefaults key）
- ADR-001（依赖白名单约束）：[`ADR-001-swiftui-native-only-stack.md`](ADR-001-swiftui-native-only-stack.md)
