# GUI 系统架构

> Version: v1.0 — 2026-05-02
> Status: Stable
> Owner: SieveAI
> 关联：PRD §3 §5 · [上游 architecture](../external/upstream-references.md#5-上游-architecture)

---

## 0. 摘要

Sieve GUI 是单进程 macOS accessory app（`LSUIElement = true`），承担 daemon 的视觉/交互层职责。
进程内分四个核心子系统：**菜单栏控制器、Window 管理器、HIPS 浮窗管理器、IPC 客户端**，加两个支撑层：**audit.db 只读视图、Touch ID 解锁会话**。

**与 daemon 完全解耦的边界**：
- GUI 不发明 IPC 字段
- GUI 不写 audit.db
- GUI 不解 SSE / 不持有规则集 / 不计算 fingerprint
- GUI 不参与决策计算（只把用户答复转给 daemon）

---

## 1. 系统级位置

```
┌─────────────────────────────────────────────────────────────┐
│                       macOS user session                     │
│                                                              │
│  ┌──────────────┐   stdio/SSE   ┌────────────────────────┐  │
│  │ Claude Code  │◄─────────────►│ ANTHROPIC_BASE_URL     │  │
│  │  / Agent     │               │   = 127.0.0.1:11453    │  │
│  └──────────────┘               └─────────────┬──────────┘  │
│                                                │              │
│                                                ▼              │
│                                ┌──────────────────────────┐  │
│                                │  Sieve daemon (Rust)      │  │
│                                │  · 检测 / 规则匹配         │  │
│                                │  · audit.db 写入           │  │
│                                │  · launchd 管的服务        │  │
│                                └────────┬─────────┬────────┘  │
│                                         │         │            │
│                  Unix Domain Socket     │         │  append-only │
│                  ~/.sieve/ipc.sock      │         ▼            │
│                  JSON-RPC 2.0 v2        │   ~/.sieve/audit.db │
│                                         │         ▲            │
│                                         ▼         │ read-only  │
│                                ┌────────────────────────────┐ │
│                                │   Sieve GUI (本仓库)         │ │
│                                │   · 菜单栏 NSStatusItem      │ │
│                                │   · HIPS 浮窗 NSPanel        │ │
│                                │   · 设置/历史/调试 Window     │ │
│                                │   · LSUIElement = true       │ │
│                                └────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

详细见上游 architecture.md §6（[`external/upstream-references.md`](../external/upstream-references.md#5-上游-architecture)）。

---

## 2. 进程内结构

```
┌────────────────────────────── SieveGUIApp ──────────────────────────────┐
│                                                                           │
│  AppDelegate (NSApplicationDelegate)                                      │
│   ├─ 启动 IPC client → 连 ~/.sieve/ipc.sock                              │
│   ├─ 注册 NSStatusItem → MenuBarController                               │
│   └─ 注册 LoginItem (SMAppService)                                        │
│                                                                           │
│  ┌──────────────────────────┐    ┌──────────────────────────┐           │
│  │  MenuBarController        │    │  WindowManager            │           │
│  │  · 状态图标 (5 种状态)     │    │  · Settings Window        │           │
│  │  · Quick Menu popover     │◄──►│  · History Window         │           │
│  │  · 暂停 / 恢复            │    │  · Debug Window           │           │
│  │                            │    │  · Onboarding Window      │           │
│  └────────────┬───────────────┘    └────────────┬─────────────┘           │
│               │                                  │                         │
│               ▼                                  ▼                         │
│  ┌──────────────────────────────────────────────────────────────┐         │
│  │  AppState (@Observable, 单例)                                  │         │
│  │   · daemonStatus: { connected, paused, preset, version }      │         │
│  │   · recentHits: [HitSummary]  (最近 3 条，IPC + audit.db)     │         │
│  │   · activeRequest: HipsRequest?  (当前显示中的弹窗)            │         │
│  │   · pendingQueue: [HipsRequest]  (等待显示的弹窗)              │         │
│  │   · unlockSession: TouchIDSession?                             │         │
│  │   · settings: UserSettings (UserDefaults 持久化)               │         │
│  └────────────┬──────────────────────────┬───────────────┬───────┘         │
│               │                           │               │                 │
│   ┌───────────▼───────────┐  ┌───────────▼─────────┐ ┌──▼──────────────┐ │
│   │  HipsPanelManager      │  │  IPCClient           │ │  AuditDBReader   │ │
│   │  · 申请 NSPanel         │  │  · UDS Connection    │ │  · SQLite.swift  │ │
│   │  · floating panel 配置  │  │  · JSON-RPC codec    │ │    read-only     │ │
│   │  · 排队串行显示         │  │  · 重连退避          │ │  · DispatchSource│ │
│   │  · 防误点 (0.4s swallow)│  │  · inflight 跟踪     │ │    file watch    │ │
│   └───────────┬───────────┘  └───────────┬─────────┘ └──┬──────────────┘ │
│               │                           │               │                 │
│               └────────────┬──────────────┴───────────────┘                 │
│                            ▼                                                │
│                   ┌────────────────────┐                                    │
│                   │  ToastController    │                                    │
│                   │  · NSPanel statusBar│                                    │
│                   │  · 5s 淡出 / 合并   │                                    │
│                   └────────────────────┘                                    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────┐       │
│  │  Support layer                                                    │       │
│  │   · TouchIDService (LAContext, 5 分钟解锁会话)                    │       │
│  │   · NotificationCenter (UNUserNotificationCenter)                 │       │
│  │   · DiagnosticPackager (导出诊断包，前置脱敏)                      │       │
│  │   · UpdateChecker (Sparkle, 仅 General → 检查更新)                │       │
│  │   · I18n (String Catalogs, zh/en)                                 │       │
│  └─────────────────────────────────────────────────────────────────┘       │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 关键控制流

### 3.1 启动序列

```
1. main()
   ├─ 创建 NSApplication
   ├─ 设置 LSUIElement = true（已在 Info.plist）
   └─ 运行 NSApplicationMain

2. AppDelegate.applicationDidFinishLaunching
   ├─ AppState.shared = AppState()
   ├─ 加载 UserSettings（UserDefaults）
   ├─ 启动 IPCClient（异步）
   │   ├─ 连接 ~/.sieve/ipc.sock
   │   ├─ 协议握手 → 收 sieve.hello
   │   └─ AppState.daemonStatus = connected
   ├─ MenuBarController 注册 NSStatusItem
   ├─ AuditDBReader 启动 → 启动 file watch
   ├─ 检查 kOnboardingCompletedAt
   │   ├─ 不存在 / sieve.hello 失败 → 弹 Onboarding Window（模态）
   │   └─ 正常 → 待命
   └─ Sparkle 启动（如果设置开启自动检查更新）
```

### 3.2 HIPS 弹窗主流程（PRD §4.1 场景 A）

```
daemon                              IPCClient                HipsPanelManager        User
  │                                     │                          │                   │
  ├─ sieve.request_decision ───────────►│                          │                   │
  │  (id, params)                       │                          │                   │
  │                                     ├─ 解码为 HipsRequest        │                   │
  │                                     ├─ AppState.pendingQueue 入 │                   │
  │                                     ├─ 通知 Manager 调度          │                   │
  │                                     │       │                  │                   │
  │                                     │       ▼                  │                   │
  │                                     │  当前无活动弹窗 → 出队     │                   │
  │                                     │  → activeRequest = req    │                   │
  │                                     │       │                  │                   │
  │                                     │       ▼                  │                   │
  │                                     │  ┌─────────────────────┐ │                   │
  │                                     │  │ NSPanel 创建/复用    │ │                   │
  │                                     │  │ .level = .floating  │ │                   │
  │                                     │  │ .canJoinAllSpaces   │ │                   │
  │                                     │  │ NSApp.activate(...) │ │                   │
  │                                     │  └─────────────────────┘ │                   │
  │                                     │                          ├─ 显示弹窗（< 500ms）
  │                                     │                          ├─ 倒计时 tick (1Hz)  │
  │                                     │                          │                   │
  │                                     │                          │   用户点 [拒绝]     │
  │                                     │                          │◄──────────────────┤
  │                                     │  ◄─ DecisionMade event  │                   │
  │                                     │     (deny, remember:false)│                   │
  │ ◄─ sieve.decision_response ─────────┤                          │                   │
  │  (id, result)                       │                          │                   │
  │                                     ├─ activeRequest = nil      │                   │
  │                                     ├─ 检查 pendingQueue        │                   │
  │                                     │   有 → 出队下一条          │                   │
  │                                     │   无 → 关闭 Panel          │                   │
  │ ─→ SSE 注入 sieve_blocked event     │                          │                   │
```

### 3.3 IPC 失联

```
IPCClient detect:
  · 连接失败 3 次（间隔指数退避 1s/2s/5s/10s/30s）
  · 30s 无心跳
        │
        ▼
  AppState.daemonStatus = disconnected
        │
        ├─ MenuBarController → 图标变红 ⚠
        ├─ 所有 Window 顶部显示 banner
        ├─ 设置面板禁用所有写入按钮
        ├─ 已显示中的 HIPS 弹窗保留（倒计时继续）
        └─ 后台持续重试连接

重连成功:
  · 收 sieve.hello → 同步 paused / preset
  · 重发所有 inflight decision_response
  · banner 消失
```

详见 [`SPEC-008-ipc-client.md`](../specs/SPEC-008-ipc-client.md)。

---

## 4. 模块边界与依赖

```
                ┌──────────────────────────────────────┐
                │   View Layer (SwiftUI Views)          │
                │   依赖 → ViewModel only              │
                └──────────┬───────────────────────────┘
                           │
                           ▼
                ┌──────────────────────────────────────┐
                │   ViewModel Layer (@Observable)       │
                │   依赖 → AppState + Services         │
                └──────────┬───────────────────────────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
      ┌────────────┐ ┌──────────┐ ┌────────────────┐
      │  AppState  │ │ Services │ │  Persistence   │
      │ (single    │ │ (IPC,    │ │  (SQLite,      │
      │  source of │ │  TouchID,│ │   UserDefaults)│
      │  truth)    │ │  Toast)  │ │                │
      └────────────┘ └──────────┘ └────────────────┘
```

**依赖规则**：
- View 只能 import ViewModel
- ViewModel 只能 import AppState 和 Service 接口
- Service 之间禁止互相依赖（统一通过 AppState 协调）
- 任何层都不能反向依赖 View

文件夹布局见 [ADR-009](adr/ADR-009-project-layout-single-target.md)。

---

## 5. 状态管理

**单一事实来源**：`AppState`（`@Observable` 单例）。
- 所有跨模块共享状态都在这里
- 每个 Window 的 ViewModel 只观察自己关心的子树
- IPC 收到的所有 daemon 推送先进 AppState，再触发 UI 更新

**为什么不分层 store**：
- App 规模有限（~7 个模块）
- macOS 14+ `@Observable` 已经做到细粒度更新
- 引入 Redux/TCA 的成本不值

**例外**：
- `pendingQueue / activeRequest` 由 HipsPanelManager 内部维护，AppState 只暴露只读视图
- `unlockSession` 由 TouchIDService 持有，AppState 只暴露 `isUnlocked: Bool`

---

## 6. 并发模型

- **主入口**：`@MainActor` 包住 AppDelegate / 所有 ViewModel
- **IPC 读写**：`Network.framework` `NWConnection` 在专用 `DispatchQueue`，结果用 `Task { @MainActor in ... }` 投递回主线程
- **audit.db 读取**：后台 `DispatchQueue`，`AsyncStream` 推回主线程
- **DispatchSource file watch**：后台队列触发，去抖 100ms 后投递主线程

**禁止**：
- 在 `@MainActor` 上做 SQLite 查询或 IPC 阻塞 I/O
- View 里 `Task { ... }` 不指定 actor（容易泄漏到非主线程）

---

## 7. 错误处理与降级

| 失败 | 检测方式 | 行为 |
|------|---------|-----|
| daemon 未启动 | `connect()` ENOENT | 进入 disconnected + Onboarding（如未完成）|
| IPC 协议版本不识别 | `sieve.hello.protocol_version` 不在白名单 | 进入 disconnected + 引导升级 |
| audit.db 不可读 | open 失败 | 历史窗口显示空状态 + 修复指引 |
| audit.db schema `user_version` 未知 | 启动检查 | 顶部 banner 警告，仍展示已知字段（fail-soft）|
| Touch ID 失败 | LAContext error | 回退脱敏视图 + 写 GUI log |
| HIPS 弹窗 UI 渲染失败 | View 异常 | 兜底退化为系统通知（"Sieve 拦截：rule_id，GUI 异常"）+ 自动 deny IPC 回 daemon |
| Sparkle 检查更新失败 | Sparkle delegate 错误 | 静默失败 + 调试 Tab 可见 |

---

## 8. 性能预算

PRD §8.1 量化要求落到架构层面：

| 指标 | 设计承诺 | 关键设计选择 |
|------|---------|-------------|
| HIPS 弹窗 P95 显示 < 500ms | NSPanel 复用 + SwiftUI View 预编译 + 预热 vibrancy | HipsPanelManager 持有一个常驻 NSPanel（隐藏态），首次显示只切内容不重建 |
| 冷启动 < 1.5s（M1）| 延迟初始化 SQLite / Sparkle / file watch | 启动只必须做：IPC 连接 + StatusItem |
| 内存 < 80MB | 每 5 分钟主动清理：已关闭 Window 的 ViewModel、过期 toast、5 分钟前的 audit follow buffer | 用 `weak` 持有 ViewModel；audit.db follow 限 100 条 ring buffer |
| Toast 渲染 < 100ms | NSPanel 同样复用 | ToastController 单例 |

---

## 9. 安全架构

详见 PRD §8.4。架构层面的关键体现：

- **网络隔离**：`com.apple.security.network.client = false`，Sparkle 例外项单独处理
- **文件权限**：`~/.sieve/` 必须 0700；GUI 启动时检查，不符合时引导
- **IPC 鉴权**：依赖 socket 文件 0600，进程内不做密码学认证
- **敏感字段隔离**：`MaskedField` 组件包住所有可能含原文的字段，禁止直接 `Text(...)`
- **导出脱敏**：`DiagnosticPackager` 是唯一可以 read evidence 的路径，强制走脱敏管线（[ADR-011](adr/ADR-011-redact-on-export.md)）

---

## 10. 变更记录

| 版本 | 日期 | 作者 | 变更 |
|------|------|-----|-----|
| v1.0 | 2026-05-02 | SieveAI | 首次起草 |
