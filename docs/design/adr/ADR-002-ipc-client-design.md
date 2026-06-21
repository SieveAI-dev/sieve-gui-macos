# ADR-002：UDS + JSON-RPC + Network.framework 的 IPC 客户端架构

> Status: Accepted
> Date: 2026-05-02
> Deciders: SieveAI
> Tags: ipc, infra

## Context

GUI 需要一个稳定、低延迟的 IPC 客户端连接 daemon，承载：

1. 接收 daemon 推送的 `sieve.request_decision`（HIPS 弹窗触发），必须 P95 < 500ms 完成从 IPC 接收到第一帧渲染
2. 发送用户决策 `sieve.decision_response`，并在重连后保证补发（inflight 队列）
3. 接收心跳 / 状态更新 / event_notify（Toast 触发）
4. 双向 request-response（`sieve.set_preset` / `sieve.evaluate` 等）

协议由上游 ADR-013 锁定：Unix Domain Socket（UDS）+ JSON-RPC 2.0 + newline-delimited JSON，协议版本 `v1`。GUI 侧只负责实现客户端，不参与协议设计。

关键约束：
- IPC 读写必须在非主线程（不能阻塞 `@MainActor`），结果投递主线程
- 失联时 inflight 决策请求不能丢失（daemon 超时按 fail-closed 兜底）
- 重连退避不能过激，30s 无心跳视为失联，socket 就绪后重连 < 100ms

## Options Considered

### Option 1：Network.framework（NWConnection）
- 优点：Apple 官方 Swift-native 框架，提供 UDS 路径连接（`NWEndpoint.unix`）；内建收包 framing（`NWProtocolFramer` 可扩展）；`stateUpdateHandler` 回调直接映射到连接状态机；无需处理 low-level read/write syscall；与 `NWPathMonitor` 联动监听网络变化（虽然 UDS 不过网络栈，但 API 一致性有价值）
- 缺点：framer API 比较陡峭；对 UDS 的 `connect` 需要处理 `.ready` 回调
- 估计成本：中等，需要写 newline-delimited framer；一次投入，后续维护低

### Option 2：POSIX socket + DispatchIO
- 优点：底层控制完整；无框架依赖
- 缺点：需要手写 read/write 缓冲区、错误处理、重连逻辑；与 Swift concurrency 集成需要大量桥接；与 `async/await` 惯用法背道而驰
- 估计成本：高，且容易出 bug（buffer split、partial read 等）

### Option 3：URLSession（WebSocket over localhost HTTP）
- 优点：Swift 友好；WebSocket framing 省心
- 缺点：daemon 协议是 UDS + JSON-RPC，不是 WebSocket；修改 daemon 协议不在 GUI 职责内；entitlement 还需要 `com.apple.security.network.client = true`，与安全架构冲突
- 估计成本：不可行（需要改 daemon 协议）

### Option 4：libdispatch + 纯 Swift Stream
- 优点：标准库无额外依赖
- 缺点：UDS async stream 需要自己管理 read continuation；错误路径繁琐；不如 NWConnection 有状态机管理
- 估计成本：中高，且错误路径风险大

## Decision

选择 Option 1：**Network.framework（NWConnection）**。

具体设计：

**传输层**：`NWConnection(to: NWEndpoint.unix(path: ipcSockPath), using: .tcp)` — 注：UDS 在 Network.framework 里实际用 `.unix` endpoint，协议栈用 `.tcp`（或自定义 framer）。

**Codec**：`Foundation JSONEncoder / JSONDecoder`，绑定到 `Codable` 结构体。禁止 `[String: Any]` 透传（CLAUDE.md 硬约束）。每条消息一行 JSON + `\n`（newline-delimited），在 `NWProtocolFramer` 里按 `\n` 分包。

**并发**：NWConnection 在专用 `DispatchQueue(label: "com.sieve.gui.ipc", qos: .userInteractive)` 运行；收到消息后用 `Task { @MainActor in ... }` 投递主线程。

**Inflight 队列**：`[String: InflightRequest]` 字典，键为 JSON-RPC id（即 request_id）。重连成功后遍历队列重发。重连后收到 daemon 的 `sieve.hello` 才正式标记 `connected`，避免竞态。

**重连退避**：指数退避 1s → 2s → 5s → 10s → 30s（封顶），由 `NWConnection.stateUpdateHandler` 的 `.failed` 状态触发。主动断连（`.cancelled`）不触发退避。

**心跳超时**：维护 `lastMessageReceivedAt`；Timer 每 10s 检查一次，30s 无消息 → 主动关闭重连。

详见 [`SPEC-008-ipc-client.md`](../../specs/SPEC-008-ipc-client.md)。

## Consequences

**正面影响**：
- NWConnection 状态机（`.preparing` / `.ready` / `.failed` / `.cancelled`）直接映射到 AppState.daemonStatus，代码简洁
- `Codable` 强类型消息结构，JSON 字段错误在编译期或解码时暴露，不会在运行时 crash
- inflight 队列 + 重连重发，保证 HIPS 弹窗显示中失联后用户决策不丢

**引入的新约束**：
- `NWProtocolFramer` API 仅 macOS 10.15+，但 deployment target 是 13，兼容
- 协议版本 `v1` 白名单检查在 `sieve.hello` 处理中强制执行，任何不在白名单的版本号立即进入 disconnected（PRD §6.1 / CLAUDE.md 硬约束 5）
- 禁止在 `@MainActor` 上做任何 IPC 阻塞 I/O（architecture.md §6 并发模型约束）
- IPC 客户端必须有 mock daemon harness 以支持单元测试（CLAUDE.md 测试约束）

**后续需要做的事**：
- 完成 SPEC-008（IPC 客户端规格）的状态机图和错误码表
- 实现 mock daemon harness：回放预录 JSON 消息序列，用于 HIPS 弹窗行为测试
- 在 CI 中加 IPC 往返延迟基准测试，保证重连 < 100ms 目标可量化

## References

- 上游 [ADR-013（ipc-protocol）](../../external/upstream-references.md#adr-013ipc-protocol)
- [`docs/api/ipc-protocol.md`](../../api/ipc-protocol.md) — 完整协议契约
- [`SPEC-008-ipc-client.md`](../../specs/SPEC-008-ipc-client.md) — 客户端实现规格
- [`docs/design/architecture.md`](../architecture.md) §3.3（IPC 失联流程）§6（并发模型）
- PRD §6.5（重连与超时）、§8.1（性能指标）
