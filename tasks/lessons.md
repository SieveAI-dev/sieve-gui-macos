# Sieve GUI macOS — 经验沉淀

> 每次踩坑/被纠正后立即追加。记录「错误模式 + 防范规则」，会话开始时回顾。

---

## L1 — 状态机禁用自身状态做守卫（自指死锁）

**2026-06-23**：`AppState.rescheduleStatus()` 用 `if case .disconnected = daemonStatus { return }` 做失联守卫，而 `daemonStatus` 初始即 `.disconnected`，导致握手成功路径（`markConnected`/`applyHello`）委托 `rescheduleStatus` 时被守卫挡回 → 图标握手后**永久卡失联**。

- **错误模式**：状态机的「是否处于态 X」判断读「当前状态值」自身，形成自指闭环，使本应推动状态迁移的合法信号失效。
- **防范规则**：失联/连接这类「事实」必须有**独立事实位**（如 `ipcConnected: Bool`），守卫读事实位而非 `daemonStatus` 自身。`daemonStatus` 是派生结果，不是判定依据。

## L2 — 纯逻辑应纳入 swift test，别留在 App target 当盲区

**2026-06-23**：上述死锁能潜伏到 187 测试全绿，根因是 `AppState`（纯逻辑、无 AppKit 依赖）被 `Package.swift` exclude 出 `SieveGUICore`，`swift test` 根本编不到它 → 状态机零测试。

- **错误模式**：把无 AppKit/SwiftUI 依赖的纯逻辑类留在 `Sources/App`（仅 xcodebuild 编），导致它脱离 `swift test` 快速反馈，bug 长期无人发现。
- **防范规则**：`Sources/App` 里只 `import Foundation/Combine/os.log` 的纯逻辑文件，应单独列入 `Package.swift` 的 `SieveGUICore` sources（exclude 改列具体 AppKit 文件，而非整个 `App` 目录）。两套构建独立（App target 自编整个 Sources、不 link 核心库），不会重复符号。

## L3 — 状态评估以代码 ground-truth 为准，不照搬 PROGRESS 勾选

**2026-06-23**：PROGRESS（6-20）既**低估**完成度（mock daemon harness / CSV-NDJSON 导出 / Toast 测试等 10 项标 `[ ]` 实际已落地）又**漏报**缺口（状态机死锁、一批死设置/假数据/死链）。

- **错误模式**：把 PROGRESS 的勾选当真相，按过时清单决策。
- **防范规则**：评估完成度先做代码 ground-truth 盘点（grep TODO/假数据/死设置 + 对照 SPEC 逐条核验「是否真接线」而非看命名/注释）；最高影响的断言亲自读源码确认再下结论；纠偏写回 PROGRESS。

## L4 — 死链的三种典型形态（盘点识别清单）

**2026-06-23**：批次 A 清理的 9 项缺口可归为三类，识别手法各不同：

- **死设置**：UI 写了 UserDefaults/设置项，但消费方读系统值/默认值、从不读该 override（如 Toast `reduceMotionOverride`、General 主题/语言）。**查法**：grep 设置项字段名，看是否有真实消费点读它。
- **死代码**：函数实现完整但无调用方（如 History `loadMore()`、Debug `setInflight`）。**查法**：grep 函数名，看调用方是否存在（只有定义=死代码）。
- **死链**：数据回写/回调链中途断了（如 schema banner 的 `reader.schemaWarning` 不回写 AppState、Toast 点击跳历史的 `audit_event_id` 恒 nil）。**查法**：从「触发点」追到「消费点」，看链路是否闭合。
- **规则**：盘点时对每个「已实现」功能问一句「它真的被接线消费了吗」，而非看命名/注释/UI 存在。

## L5 — 并行子代理必须先画互斥文件边界矩阵

**2026-06-23**：6 个 agent 并行改 Features 零冲突，前提是开工前画了文件边界矩阵确认无重叠写。

- **错误模式**：派多个实现 agent 前不规划文件边界，多个 agent 写同一文件 → 后写覆盖先写 / 合并冲突。
- **防范规则**：派并行实现 agent 前列「文件→唯一 agent」矩阵；同模块多项（如 History 三项都在 `Features/History`）合并给**一个** agent；共享核心文件（如 `AppState`/`UserSettings`）只分配给一个 agent，并在 prompt 明确**禁改区域**（如「只加 setter，禁碰刚修好的状态机」）。

## L6 — Test debt 的「假信心」：测试存在 ≠ 测了真实路径

**2026-06-23**：盘点发现多个测试给假信心——`ToastReduceMotionTests` 只断言常量集合合法（没验 override 真驱动）；`HipsRedLineTests` 把 `currentPhase` 阈值公式**内联重写**（没调真实 currentPhase，公式漂移不报警）；`DiagnosticPackagerTests` 用裸 SQLite 复现脱敏逻辑（没调真实 packager）。

- **错误模式**：测试重写/mock 了一份「等价逻辑」而非调用真实生产函数，生产代码漂移时测试不变红。
- **防范规则**：测试必须实例化/调用**真实生产路径**。本次 ReduceMotion 修复即让测试调真函数 `UserSettings.reduceMotionEnabled(...)`，而非复制其分支。Review 测试时问：它调的是生产代码，还是一份副本？

## L7 — 跨仓枚举外取值用局部 tolerant 解码，别污染全局枚举

**2026-06-23**：C1 跨仓查证发现 daemon evaluate 对非 critical_lock 命中回 `severity:"unknown"`，GUI `Severity` enum 无该 case → 整个 `EvaluateResult` 解码失败丢结果。

- **错误模式（诱惑）**：给全局 `Severity` 加 `unknown` case。但 `Severity.allCases` 被 History 筛选 Picker 用（`HistoryWindowView` ForEach），加 case 会污染筛选选项 + 改 sortOrder/Comparable 语义。
- **防范规则**：枚举外取值只在**受影响的 DTO 局部容错**（`EvaluateResult.Match.severity → Severity?` + `Severity(rawValue:)` 失败转 nil），不动全局枚举。跨仓 wire 字段解码优先 tolerant（`decodeIfPresent` + `rawValue` init）over 严格 `decode`，避免 daemon 一个枚举外值丢整条消息。改 enum 前先 grep `allCases` 看影响面。

## L8 — subagent 产出必须验证，别信 "done" 直接落盘

**2026-06-23**：批次 C/D 7 个 agent 全报 `done`，但 D6 `AuditDBReaderTests` 文件末尾混入工具标记 `</content></invoke>` 致编译失败；且 D6 的 setenv HOME 可测性方案有缺陷（`AuditDBReader.dbPath` 是 static let，解析时机不可控 → 触发 fail-safe precondition crash，signal 5 拖垮整个 test）。

- **错误模式**：信任并行 agent 自报 done，直接落盘/标记完成。
- **防范规则**：并行实现后强制三步验证——①`grep` 扫描标记泄漏（`</content>`/`</invoke>`/`<parameter`）；②`swift test` + `xcodebuild` 编译/运行验证（agent 被禁跑构建，主上下文必须补全）；③Review agent 自报的「可测性方案」是否真可靠——D6 的 setenv hack 不可靠，正解是给生产代码加注入点（`AuditDBReader.open(path:)` 默认参数注入）。**agent done ≠ 验证通过**。
