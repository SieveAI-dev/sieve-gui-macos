# SPEC-003：设置窗口

> Version: v1.0 — 2026-05-02
> Status: Stable
> Owner: doskey
> 关联 ADR：ADR-001, ADR-003, ADR-005, ADR-007, ADR-008, ADR-010, ADR-011
> 关联 PRD 章节：§5.3

---

## 0. 摘要

设置窗口是 Sieve GUI 的配置中心，包含 6 个 Tab：General（通用）/ Detection Preset（检测模式）/ Privacy & Data（隐私数据）/ Daemon（守护进程）/ Updates（更新）/ About（关于）。通过 `⌘,` 或 Quick Menu 入口唤起，单实例窗口。

---

## 1. 范围与非目标

**范围**：
- 6 个 Tab 的内容规格与交互
- 检测 preset 切换（IPC `sieve.set_preset` / `sieve.set_preset_overrides`）
- 灰名单管理 sheet
- Touch ID 保护的高危操作（清空历史）
- 诊断包导出
- Sparkle 更新检查

**非目标**：
- 用户规则 TOML 文件的 GUI 编辑器（Phase 1 排除，PRD §10）
- daemon 更新（GUI 不替 daemon 推更新）

---

## 2. 用户路径 / 场景

### 场景 A：切换 Detection Preset
1. 打开设置 → Detection Preset Tab
2. 选 Strict（从 Standard）
3. 确认 alert："切换将影响 N 条规则的超时和默认行为，确定？"
4. 确认 → IPC `sieve.set_preset{mode:"Strict"}` → 等待 response
5. 成功 → Tab 显示更新，菜单栏 Quick Menu 同步

### 场景 B：Custom preset 修改单条规则
1. Detection Preset Tab → 切到 Custom
2. 规则表中找到 `IN-GEN-04`，点 `…` → [编辑超时]
3. 修改 `timeout_seconds = 60`（原 30）
4. IPC `sieve.set_preset_overrides{mode:"Custom", overrides:[...]}`
5. critical_lock 规则（IN-CR-01, IN-CR-05）行：字段展示但禁用编辑，hover tooltip

### 场景 C：灰名单管理
1. Privacy & Data Tab → [打开灰名单管理]
2. sheet 弹出：列出所有 `GraylistEntry`（来自 IPC `sieve.list_graylist`）
3. 选中某条 → [删除] → 确认 → IPC `sieve.remove_graylist{fingerprint}`
4. 成功 → 列表实时更新

### 场景 D：导出诊断包
1. About Tab → [导出诊断包]
2. `DiagnosticPackager` 执行：脱敏 audit.db → NDJSON + 脱敏 daemon.log/err + gui.log
3. Save panel 选保存路径
4. 压缩为 `sieve-diagnostic-YYYYMMDD.zip`
5. 打开 Finder 显示文件位置

---

## 3. 状态机

```
closed ──⌘, / 菜单入口──► open (active tab = general)
                               │
               切 tab          │   IPC 失联
               ┌───────────────┤─────────────────────┐
               │               │                     ▼
         tab 内部状态         (tab 顶部 banner)  写入按钮全部禁用
         (见各 tab 子节)
               │
        关闭窗口
               ▼
             closed
```

---

## 4. UI 规格

### 4.1 窗口形态

- 类型：`NSWindow` + SwiftUI `Settings` scene（macOS 13+）
- 尺寸：760×600pt，不可调整小于此（内容可滚动）
- 单实例：`⌘,` 再次触发时聚焦已存在窗口
- Tab 布局：窗口顶部 segmented control（紧贴 titlebar 下方）

### 4.2 Tab 导航

```
[⚙ General] [🛡 Detection] [👁 Privacy] [💻 Daemon] [⬇ Updates] [ℹ About]
```

切换 Tab 时保留各 Tab 的滚动位置。

**IPC 失联时**：所有 Tab 顶部显示 banner："与 daemon 失联，显示数据可能过时。写入操作已禁用。"；Detection / Daemon Tab 的写入按钮全部禁用（不影响 General / About / Privacy 本地设置）。

### 4.3 General Tab

控件清单（左 label 200pt，右区域自适应，`FieldRow` 布局）：

| 控件 | 类型 | 默认 | 存储 |
|------|------|-----|-----|
| 启动时打开 GUI | Toggle | 开 | `SMAppService` + `kLoginItemEnabled` |
| 主题 | Picker（system / light / dark）| system | `kAppearance` |
| 语言 | Picker（跟随系统 / 中文 / English）| 跟随系统 | `kLanguage` |
| 弹窗提示音 | Toggle + [试听] 按钮 | 开（Funk）| `kHipsSoundEnabled` + `kHipsSoundName` |
| 减少动效 | Picker（system / on / off）| system | `kReduceMotionOverride` |
| Toast 显示时长 | Stepper 输入框（3~10）| 5 | `kToastDurationSeconds` |

提示文字：
- 语言 hint："仅影响 GUI 文案；daemon 推送的 rule title 由 daemon 处理"
- 弹窗提示音 hint："HIPS 弹窗触发时播放（Funk）"
- 减少动效 hint："覆盖系统级 reduce-motion 设置"

### 4.4 Detection Preset Tab

**Preset 选择区**：
```
[Strict]  [Standard ✓推荐]  [Relaxed]  [Custom]
          （4宫格，选中项白卡样式）
```

选中项下方展示说明卡（PRD §5.3.2）：

| Preset | 图标 | 颜色 | 说明要点 |
|--------|-----|------|---------|
| Strict | 盾牌 | 红色 | 所有超时 ×0.5；OUT-06~10 一律拒绝；Inbound Critical 不可灰名单 |
| Standard | 对勾 | 绿色 | 默认；Critical 超时 30/60s；OUT-01~05 自动脱敏；Critical Lock 启用 |
| Relaxed | ℹ | 橙色 | 所有超时 ×2；IN-GEN-01~03 改 fail-open；Critical 行为不变 |
| Custom | 扳手 | 灰色 | 逐规则覆盖；从当前模式分叉；Critical Lock 仍生效 |

切换 preset 弹确认 alert（只有从当前 preset 切到其他才弹）。`changed_by="gui"` 收到 `sieve.preset_changed` notification 时不重复刷新（避免闪烁）。

**规则总览表**（`GroupBox` 内）：

```
Dir  rule_id          severity  disposition    timeout  default  操作
─── ──────────────── ──────────  ─────────────  ───────  ───────  ──
Out  OUT-01           critical  AutoRedact     —        —        …
Out  OUT-07           critical  GuiPopup       60       Block    …
In   IN-CR-01         critical  GuiPopup       60       Block    🔒
In   IN-CR-05         critical  GuiPopup       120      Block    🔒
In   IN-GEN-04        high      GuiPopup       30       Block    …
...
user: MY-CURL-PIPE   medium    StatusBar      —        —        …  ← user: 前缀
```

- 列宽：Dir 44 / rule_id 156 / severity 70 / disposition 110 / timeout 60 / default 68 / 操作 28
- critical_lock 行（🔒）：timeout 和 default 字段展示但禁用编辑，hover tooltip："此规则在 critical_lock 中，不可修改"
- `user:` 前缀规则：蓝色文字，折叠在"用户规则"区域，状态栏标注"由 sieve rules edit 管理"
- 操作列（`…`）弹出菜单：[查看规则源码（只读）] / [打开关联文档]（外链，走系统浏览器）
- 用户规则折叠区底部：[在 Finder 中显示] / [运行 sieve rules edit]（spawn 终端，`$EDITOR`）

Custom preset 下可编辑非 critical_lock 规则的 `timeout_seconds`（30~600）和 `default_on_timeout`（Block/Allow）。保存时发 IPC `sieve.set_preset_overrides`。

### 4.5 Privacy & Data Tab

控件清单：

| 控件 | 类型 | 默认 | 行为 |
|------|------|-----|-----|
| 历史记录默认脱敏 | Toggle | 开 | `kHistoryMaskByDefault`；关闭后仍需 Touch ID 解锁查看 |
| 审计日志保留 | Picker（30/90/180/无限 天）| 90 | 写 daemon 配置（IPC `sieve.set_preset_overrides` 的 retention 字段，待确认） |
| 记录调用进程 | Toggle | 开 | 写 daemon 配置；关闭后 `caller_pid/exe` 为 NULL（PRD §5.3.3）|
| 灰名单管理 | 按钮 [打开灰名单管理（N 条）] | — | 弹独立 sheet（见 §4.5.1）|
| 清空历史 | 按钮（danger 样式）| — | 不可逆，需 Touch ID 二次确认 |

**hint 文字**：
- 记录调用进程 hint："caller_pid + caller_exe；关闭后字段为 NULL（PRD v2.0 §5.6）"
- 历史默认脱敏 hint："关闭后仍需 Touch ID 解锁查看敏感字段"

#### 4.5.1 灰名单管理 Sheet

```
┌─────────────────────────────────────────────────────────┐
│  灰名单管理                                [关闭]         │
├─────────────────────────────────────────────────────────┤
│  fingerprint       rule_id     创建时间   触发次数  操作  │
│  7a3f...e9c2       IN-GEN-04   2026-04-29  4        [删除]│
│  ...                                                    │
│                                                         │
│  共 12 条                                                │
└─────────────────────────────────────────────────────────┘
```

- 打开时调用 IPC `sieve.list_graylist` 拉取列表（见 [ipc-protocol §4.6](../api/ipc-protocol.md#46-sievelist_graylist--sieveremove_graylist)）
- [删除] → 确认 alert → IPC `sieve.remove_graylist{fingerprint}` → 列表刷新
- fingerprint 显示短前缀（8 字符）
- IPC 失联时 sheet 禁用"删除"操作

### 4.6 Daemon Tab

分三个 GroupBox：运行状态 / 配置文件 / 操作。

**运行状态**（来自 `sieve.hello` 握手数据）：

| 字段 | 值 |
|------|----|
| daemon 版本 | `sieve.hello.daemon_version` |
| 协议版本 | `v1 ✓`（绿色）/ 版本不匹配显示红色 + [运行 sieve setup 升级] 按钮 |
| 监听地址 | `127.0.0.1:11453` |
| 启动时间 | 相对时间（"2 小时 13 分前"）|

**配置文件**：

| 字段 | 内容 |
|------|-----|
| 配置 | `~/.sieve/sieve.toml` + [在 Finder 中显示] |
| 审计 DB | `~/.sieve/audit.db` + 文件大小 + [在 Finder 中显示] + 提示文字 |

审计 DB 提示文字（固定显示）："勿用其他工具写入，会破坏 append-only 触发器。"

**操作**（一行 3 个按钮）：
- [Reload 配置]：IPC `sieve.reload_config`，成功后 toast "配置已重载（N 条规则）"
- [重启 daemon]：`launchctl kickstart -k gui/$UID/com.sieve.daemon`（spawn 子进程）
- [运行 sieve doctor]：spawn 终端，结果回填下方文本区

### 4.7 Updates Tab

布局：顶部 GroupBox（居中显示图标 + 版本 + 状态），底部 GroupBox（自动检查设置）。

顶部：
- 应用图标（48pt squircle）
- "Sieve GUI 1.0.0"（14pt bold）
- "build YYYY-MM-DD · sha xxxxxxx"（11pt mono 次要色）
- 当前更新状态（"已是最新版本" 绿色 / "有新版本可用" 蓝色 + 下载按钮）
- [检查更新] 主按钮

底部：
- `kAutoCheckUpdates` Toggle（默认开，Sparkle 自动检查）
- hint："Sparkle EdDSA 签名 + appcast"

Sparkle 集成见 [ADR-010](../design/adr/ADR-010-distribution-sparkle-notarization.md)。

### 4.8 About Tab

应用图标（64pt）+ 应用信息 + 操作按钮。

| 字段 | 内容 |
|------|-----|
| 名称 | Sieve |
| 简介 | "本地的、不联网的代理守门人"（一行）|
| 版本 | `1.0.0 · build YYYY-MM-DD · sha xxxxxxx`（mono）|

操作按钮（一行）：
- [导出诊断包]：`DiagnosticPackager`（先脱敏再压缩，见 PRD §8.3 和 [ADR-011](../design/adr/ADR-011-redact-on-export.md)）
- [重新运行引导]：弹 Onboarding 窗口

额外链接：帮助 / 反馈邮箱 / 开源声明（SwiftUI 依赖列表）。

---

## 5. 数据契约

| 操作 | IPC 方法 | 格式参考 |
|------|---------|---------|
| 切换 preset | `sieve.set_preset` | [ipc-protocol §4.3](../api/ipc-protocol.md#43-sieveset_preset--sieveset_preset_overrides) |
| 修改规则覆盖 | `sieve.set_preset_overrides` | [ipc-protocol §4.3](../api/ipc-protocol.md#43-sieveset_preset--sieveset_preset_overrides) |
| 重载配置 | `sieve.reload_config` | [ipc-protocol §4.4](../api/ipc-protocol.md#44-sievereload_config) |
| 列出灰名单 | `sieve.list_graylist` | [ipc-protocol §4.6](../api/ipc-protocol.md#46-sievelist_graylist--sieveremove_graylist) |
| 删除灰名单条目 | `sieve.remove_graylist` | [ipc-protocol §4.6](../api/ipc-protocol.md#46-sievelist_graylist--sieveremove_graylist) |
| preset 外部变更通知 | `sieve.preset_changed` | [ipc-protocol §3.4](../api/ipc-protocol.md#34-sievepreset_changed通知) |

UserDefaults schema 见 [data-model.md §1](../design/data-model.md#1-userdefaults-schema)。

---

## 6. 错误与降级

| 条件 | 行为 |
|------|-----|
| IPC 失联 | 顶部 banner；Detection/Daemon Tab 写入按钮禁用 |
| `sieve.set_preset` 失败 | Toast 错误提示；preset picker 回滚到原值 |
| `critical_lock_violation`(-32010) | alert："此规则受 critical_lock 保护，修改被拒绝" |
| `sieve.reload_config` 失败 | Toast 错误提示（含 warnings 信息）|
| `sieve.list_graylist` 失败 | sheet 显示"加载失败，请重试"+ 重试按钮 |
| 诊断包导出失败（权限/磁盘满）| alert 错误 + 建议检查磁盘空间 |
| Touch ID 失败（清空历史）| 回退，不执行清空；写 GUI log |

---

## 7. 性能与硬约束

| 指标 | 约束 | 来源 |
|------|------|------|
| 设置窗口打开延迟 | < 3s（含 IPC 请求数据）| PRD §2.2 |
| IPC 失联时写入操作 | 全部禁用（防状态分裂）| PRD §5.1.4 |
| critical_lock 规则 | timeout / default 字段禁止编辑 | ADR-021 / PRD §5.3.2 |
| 用户规则编辑器 | Phase 1 不提供，只显示路径和外部编辑入口 | PRD §10 |
| 导出诊断包 | 强制脱敏，不依赖用户阅读条款 | PRD §9 #10 / ADR-011 |
| 清空历史 | 必须 Touch ID 二次确认 | PRD §5.3.3 / ADR-008 |
| 自动检查更新 | 使用 Sparkle EdDSA；GUI 不嵌入 daemon 更新 | ADR-010 / PRD §5.3.5 |

---

## 8. 测试要求

- General Tab：Toggle 值与 `UserDefaults` 同步
- Detection Tab：切 preset → 确认 alert 弹出 → 确认 → IPC 调用验证
- Detection Tab：critical_lock 规则行的编辑禁用验证（断言 timeout / default 控件 disabled）
- Detection Tab：`changed_by="gui"` 的 `preset_changed` notification 不触发重复刷新
- Privacy Tab：灰名单 sheet 打开 → `list_graylist` IPC 调用 → 列表渲染
- Privacy Tab：删除灰名单 → 确认 → `remove_graylist` IPC → 列表条目减少
- Privacy Tab：清空历史 → Touch ID mock 失败 → 不执行清空
- Daemon Tab：`reload_config` 成功 → Toast 含规则数量
- Daemon Tab：`critical_lock_violation` response → alert 渲染
- About Tab：导出诊断包 → 断言生成的 zip 中无 evidence_meta 原始字段（脱敏验证）
- IPC 失联 → Detection Tab 写入按钮 disabled 断言

---

## 9. 未决事项（OQ）

| 编号 | 问题 | 当前选项 | 截止决策 |
|------|------|---------|---------|
| OQ-003-01 | "审计日志保留"写 daemon 配置的 IPC 方法？当前 ipc-protocol 未定义此接口 | 可能走 `sieve.set_preset_overrides` 的扩展字段，或单独 `sieve.set_audit_retention` | Week 7 与 daemon 对齐 |
| OQ-003-02 | "记录调用进程"切换的 IPC 接口同上 | 同上 | Week 7 |

---

## 10. 变更记录

| 版本 | 日期 | 作者 | 变更 |
|------|------|-----|-----|
| v1.0 | 2026-05-02 | doskey | 首次起草 |
