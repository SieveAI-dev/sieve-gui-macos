# SPEC-008：IPC 客户端实现规格

> Version: v1.0 — 2026-05-02
> Status: Stable
> Owner: SieveAI
> 上游契约：[上游 ipc-protocol 决策](../external/upstream-references.md#ipc-protocol) · [ipc-protocol.md](../api/ipc-protocol.md)

---

## 0. 摘要

`IPCClient` 是 GUI 与 daemon 通信的唯一通道，基于 `Network.framework`（`NWConnection`），连接 `~/.sieve/ipc.sock`（Unix Domain Socket）。消息格式为 newline-delimited JSON，协议层为 JSON-RPC 2.0。`IPCClient` 负责：连接管理与指数退避重连、newline-delimited JSON 的编解码、inflight 队列（重连后同 request_id 重发）、30s 心跳超时检测、协议版本校验。

---

## 1. 范围与非目标

**范围**：
- `NWConnection` 状态机（连接 / 断开 / 重连）
- 指数退避重连（1s / 2s / 5s / 10s / 30s 封顶）
- newline-delimited JSON 编解码（`\n` 终止符）
- inflight 队列管理（`[String: InflightRequest]`）
- 30s 心跳超时检测
- `sieve.hello` 握手与协议版本校验
- 所有 IPC 方法的发送与接收路由
- AppState 联动（状态变更通知主线程）

**非目标**：
- IPC 消息的业务逻辑处理（各 UI 模块各自处理 HIPS/Toast/preset 变更）
- `~/.sieve/ipc.sock` 的创建（daemon 负责）
- 消息加密 / 密码学认证（依赖 socket 文件系统权限 0600）

---

## 2. 用户路径 / 场景

IPCClient 对用户不直接可见，但驱动所有 GUI 功能。关键场景：

### 场景 A：正常启动连接
```
AppDelegate.applicationDidFinishLaunching
  → IPCClient.connect()
  → NWConnection 建立 → 收 sieve.hello
  → 协议版本校验 ✓ → AppState.daemonStatus = .connected
  → 同步 paused / preset / audit_db_user_version
```

### 场景 B：连接失败，指数退避重连
```
connect() → ENOENT / 超时
  → 等待 1s → 重试 → 失败 → 等待 2s → 重试 → 失败
  → 等待 5s / 10s / 30s（封顶）
  → 第 3 次失败时 AppState.daemonStatus = .disconnected
  → 后台持续重试，成功后恢复
```

### 场景 C：弹窗已显示，IPC 中断，重连后重发
```
HIPS 弹窗显示中 → IPC 断开
  → 用户点"拒绝" → decision_response 入 disconnectedCache
  → 重连后收 sieve.hello → 遍历 disconnectedCache
  → 重发 decision_response（同 request_id）
  → daemon 端去重保护（同 id 二次响应被安全忽略）
```

### 场景 D：协议版本不识别
```
收 sieve.hello{protocol_version:"v1"}
  → "v1" 不在白名单 ["v2"]
  → 关闭 NWConnection
  → AppState.daemonStatus = .disconnected
  → 不再自动重连（避免 loop）
  → UI 显示"协议版本不匹配，请升级 GUI"
```

---

## 3. 状态机

```
                connect() 调用
  idle ─────────────────────────────► connecting
                                           │
              NWConnection.stateHandler    │
                                           ▼
                    .ready         ────► connected
                    .failed        ────► retrying
                    .waiting       ──── （保持 waiting，等 NWConnection 内置重连）
                    .cancelled     ────► idle（主动断开）

  connected:
    收 sieve.hello → 协议版本校验
      版本 OK  → active（正常收发）
      版本不识别 → cancel() → version_mismatch（不再重连）

  retrying:
    第 N 次重试（N ≤ 3）→ 继续重试
    第 3 次（3次累计失败）→ AppState.daemonStatus = .disconnected
    （仍在后台保持退避重试）

  active:
    30s 无任何消息 → timeout → cancel() → retrying

  version_mismatch（terminal）:
    不再自动重连
    UI 提示升级
```

---

## 4. UI 规格

IPCClient 无直接 UI；状态变化通过 `AppState` 驱动 UI 更新：

| IPCClient 状态 | AppState.daemonStatus | 菜单栏图标 |
|--------------|---------------------|----------|
| idle / connecting | disconnected（初始）| — |
| active（hello 成功）| connected | normal |
| retrying（< 3 次失败）| 不变（UI 不跳动）| — |
| retrying（≥ 3 次失败）| disconnected | ⚠ |
| version_mismatch | disconnected（专用状态）| ⚠ + 升级提示 |

---

## 5. 实现规格

### 5.1 NWConnection 配置

```swift
let endpoint = NWEndpoint.unix(path: socketPath)
let parameters = NWParameters()
parameters.allowLocalEndpointReuse = true
parameters.requiredInterfaceType = .loopback  // UDS 不走网络接口，此为兜底

let connection = NWConnection(to: endpoint, using: parameters)
connection.stateUpdateHandler = { [weak self] state in
    Task { @MainActor in self?.handleStateChange(state) }
}
connection.start(queue: ipcQueue)  // 专用 DispatchQueue，不占主线程
```

socket 路径：`NSHomeDirectory() + "/.sieve/ipc.sock"`，权限校验（0600）在首次连接前执行。

### 5.2 newline-delimited JSON 编解码

**发送**：
```swift
func send<T: Encodable>(_ message: T) throws {
    let data = try JSONEncoder().encode(message)
    // 追加 \n
    var frame = data
    frame.append(contentsOf: [0x0A])  // '\n'
    connection.send(content: frame, completion: .contentProcessed { error in
        if let error { /* 写 gui.log */ }
    })
}
```

**接收**：维护接收缓冲区 `receiveBuffer: Data`，循环 receive：
```
loop:
  connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576)  // 1MB 上限
  → append 到 receiveBuffer
  → 找 \n 分割
  → 每个 \n 之前的完整片段 → JSONDecoder().decode(JSONRPCMessage.self, from: fragment)
  → dispatch 到对应 handler
  → 更新 lastMessageTimestamp（心跳超时用）
  → 继续 loop
```

**单条消息最大尺寸**：1MB（防止超大 payload 撑爆缓冲区）。超过 1MB 的消息视为协议错误，关闭连接并进入 retrying。

**JSON 解码策略**：
- 使用 `Codable` 结构体，禁止 `[String: Any]` 透传（CLAUDE.md 编码规范）
- 未知字段必须忽略（`keyDecodingStrategy = .useDefaultKeys`，不设 `forbidUnknownKeys`）
- 解码失败：写 GUI log（含原始 bytes 长度），跳过该条消息，不关闭连接

### 5.3 消息路由

```swift
enum JSONRPCIncoming {
    case request(id: String, method: String, params: Data)   // daemon → GUI，含 id
    case notification(method: String, params: Data?)          // daemon → GUI，无 id
    case response(id: String, result: Data)                   // GUI 发出请求的响应
    case errorResponse(id: String, code: Int, message: String, data: Data?)
}

func route(_ incoming: JSONRPCIncoming) {
    switch incoming {
    case .notification(let method, _):
        switch method {
        case "sieve.hello":             handleHello(...)
        case "sieve.heartbeat":         handleHeartbeat()
        case "sieve.request_decision":  // 含 id，见下
        case "sieve.request_decision_canceled": handleCanceled(...)
        case "sieve.notify_status_bar": handleStatusBarNotify(...)
        case "sieve.preset_changed":    handlePresetChanged(...)
        default:                        // 未知 method，写 log，不报错
        }
    case .request(let id, let method, _):
        switch method {
        case "sieve.request_decision":  handleDecisionRequest(id: id, ...)
        default:
            // 按 JSON-RPC 规范回 method_not_found（-32601）
            sendError(id: id, code: -32601, message: "method_not_found")
        }
    case .response(let id, _):
        fulfillInflight(id: id, result: ...)
    case .errorResponse(let id, ...):
        rejectInflight(id: id, error: ...)
    }
}
```

### 5.4 inflight 队列

```swift
actor InflightQueue {
    private var queue: [String: InflightContinuation] = [:]

    func enqueue(id: String, continuation: CheckedContinuation<Data, Error>) {
        queue[id] = continuation
    }

    func fulfill(id: String, result: Data) {
        queue.removeValue(forKey: id)?.resume(returning: result)
    }

    func reject(id: String, error: Error) {
        queue.removeValue(forKey: id)?.resume(throwing: error)
    }

    // 重连时重发所有 inflight（由 IPCClient 负责）
    func allPendingIDs() -> [String] { Array(queue.keys) }
}
```

重连后重发逻辑：
1. `sieve.hello` 握手完成（协议版本 OK）
2. 遍历 `InflightQueue.allPendingIDs()`
3. 每个 inflight request：重新 `send`（同 id、同 method、同 params）
4. daemon 端有去重保护（同 id 的响应只处理一次）

`disconnectedCache`（弹窗决策缓存）：
- `decision_response` 本质上也是 inflight 的一种，但其生命周期跨越断连
- 重连后即发（优先于其他 inflight）

### 5.5 心跳超时

```swift
var lastMessageTimestamp: Date = .distantPast
let heartbeatTimeout: TimeInterval = 30

// 每 10s 检查一次
Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
    guard let self else { return }
    if Date().timeIntervalSince(self.lastMessageTimestamp) > self.heartbeatTimeout {
        // 30s 无任何消息 → 认为失联
        self.connection.cancel()  // 触发 stateHandler(.cancelled) → retrying
        self.log("heartbeat timeout, reconnecting")
    }
}
```

daemon 每 25s 发一次 `sieve.heartbeat`，GUI 30s 超时有 5s 余量（ipc-protocol §2）。

### 5.6 指数退避重连

```swift
let backoffSchedule: [TimeInterval] = [1, 2, 5, 10, 30]
var retryCount = 0

func scheduleReconnect() {
    let delay = backoffSchedule[min(retryCount, backoffSchedule.count - 1)]
    retryCount += 1
    if retryCount >= 3 {
        // 标记 disconnected（UI 变红）
        Task { @MainActor in AppState.shared.daemonStatus = .disconnected }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
        self?.connect()
    }
}

// 连接成功后重置
func onConnected() {
    retryCount = 0
    Task { @MainActor in AppState.shared.daemonStatus = .connected }
}
```

**版本不匹配**时：不进入退避重连循环（避免无意义 loop）。`retryCount` 设为 `Int.max`，`scheduleReconnect` 内检查并 `return`。

### 5.7 sieve.hello 处理

```swift
func handleHello(_ params: HelloParams) {
    guard params.protocolVersion == "v2" else {
        // 不识别的版本 → 关闭连接，进入 version_mismatch
        connection.cancel()
        Task { @MainActor in
            AppState.shared.daemonStatus = .disconnected
            AppState.shared.ipcVersionMismatch = true  // 触发 UI 升级提示
        }
        return
    }
    // 版本 OK
    UserDefaults.standard.set(params.daemonVersion, forKey: "kLastSeenDaemonVersion")
    Task { @MainActor in
        AppState.shared.daemonStatus = params.paused ? .paused : .connected
        AppState.shared.preset = params.preset
        AppState.shared.auditDbUserVersion = params.auditDbUserVersion
    }
    // 重发所有 inflight（含 disconnectedCache）
    resendInflight()
}
```

协议版本白名单：`["v2"]`（硬编码，随编译而定）。

---

## 6. 错误与降级

| 条件 | 行为 |
|------|-----|
| socket 不存在（ENOENT）| 进入退避重连 |
| socket 权限不是 0600 | 写 GUI log warn；仍尝试连接（由 OS 决定是否拒绝）|
| `sieve.hello.protocol_version` 不识别 | 关闭连接，进入 version_mismatch（不再自动重连）|
| 30s 无心跳 | 关闭连接，进入 retrying |
| 收到 > 1MB 单条消息 | 关闭连接（视为协议错误），进入 retrying |
| JSON 解码失败 | 跳过该条，写 GUI log，继续接收 |
| send() 失败 | 写 GUI log error；若是 decision_response → 入 disconnectedCache 等重连重发 |
| inflight 超时（60s 无响应）| reject 对应 continuation；调用方收到 `IPCError.timeout` |

---

## 7. 性能与硬约束

| 指标 | 约束 |
|------|------|
| IPC 重连耗时（socket 已就绪）| < 100ms |
| 退避封顶 | 30s |
| 心跳超时 | 30s |
| 协议版本不识别 | 立即进入 disconnected，不兼容旧字段 |
| 消息体最大 | 1MB（单条）|
| decision_response.remember | `allow_remember == false` 时编码层强制 `false` |
| 主线程保护 | NWConnection 在专用 DispatchQueue；结果用 `Task { @MainActor }` 投递 |
| 禁止 `[String: Any]` 透传 | 所有 IPC 消息走 `Codable` 结构体 |

---

## 8. 测试要求

### 单元测试（mock daemon harness）

**连接与握手**：
- mock daemon 发 `sieve.hello{protocol_version:"v2"}` → 断言 `AppState.daemonStatus == .connected`
- mock daemon 发 `sieve.hello{protocol_version:"v99"}` → 断言 `daemonStatus == .disconnected` + `ipcVersionMismatch == true`，且不再自动重连

**重连退避**：
- mock daemon 连接拒绝 3 次 → 断言 `AppState.daemonStatus == .disconnected`
- mock 重连成功 → 断言 `daemonStatus == .connected`，`retryCount` 重置
- 退避时序：断言第 1 次 retry 在 ~1s 后，第 2 次 ~2s，第 3 次 ~5s（允许 ±200ms 误差）

**心跳超时**：
- mock 30s 无任何消息（mock `lastMessageTimestamp` 为 31s 前）→ 断言连接被关闭，重连触发

**inflight 队列**：
- 发送 `sieve.set_preset` → mock daemon 不响应 → mock 断连重连 → 断言同 id 的 request 被重发
- 发送 `decision_response`（disconnectedCache 路径）→ 断言重连后发出

**newline-delimited JSON**：
- 发送消息 → 断言编码后末尾有 `\n`
- 接收缓冲区含两条拼接消息（`msg1\nmsg2\n`）→ 断言解码出 2 条消息
- 接收不完整消息（`msg` 无 `\n`）→ 断言不解码，等待更多数据
- 接收超大消息（> 1MB）→ 断言连接关闭

**协议约束**：
- `allow_remember == false` + GUI 构造 `decision_response{remember: true}` →
  断言发出的 JSON `remember` 字段为 `false`（编码层 reject）

### 失败注入测试

- 连接过程中 socket 文件被删除 → 断言 retrying + 退避
- 收到格式错误的 JSON（`{bad json`) → 断言跳过，不 crash，不关闭连接
- 收到超长行（单行 2MB）→ 断言连接关闭并重连
- 发送时 NWConnection 内部错误 → 断言写 GUI log，`decision_response` 入 disconnectedCache

---

## 9. 变更记录

| 版本 | 日期 | 作者 | 变更 |
|------|------|-----|-----|
| v1.0 | 2026-05-02 | SieveAI | 首次起草 |
