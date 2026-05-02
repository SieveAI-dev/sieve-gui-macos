# ADR-005：SQLite.swift 只读直连 audit.db + DispatchSource file watch

> Status: Accepted
> Date: 2026-05-02
> Deciders: doskey
> Tags: infra, security

## Context

历史窗口（SPEC-004）需要展示 daemon 写入的 audit.db 中的事件列表。

数据访问有两个备选路径：

1. **通过 IPC 拉取**：GUI 向 daemon 请求历史数据，daemon 从 SQLite 读后通过 JSON-RPC 返回
2. **直连 audit.db 只读**：GUI 直接以 read-only 模式打开 SQLite 文件，本地查询

核心约束：
- daemon 是 audit.db 的唯一写入者，有 append-only 触发器保护（上游 data-model.md §6）
- GUI 绝不写 audit.db（architecture.md §0 边界约束）
- 历史窗口加载 1 万条事件 < 500ms（PRD §8.1）
- IPC 的 `protocol_version` 不兼容时 GUI 进入 disconnected，历史窗口此时仍应能查看（只读，不依赖 IPC）

## Options Considered

### Option 1：通过 IPC 拉取历史（daemon 中继）
- 优点：GUI 无需直接处理 SQLite，所有数据访问走统一 IPC 通道；daemon 可以做分页、过滤的 server-side 优化
- 缺点：
  - 流量翻倍：daemon 需要读 SQLite → 序列化 JSON → 通过 socket 发给 GUI → GUI 反序列化；历史窗口查询频繁（filter 变化、搜索），每次都走 IPC 放大延迟
  - IPC 失联时历史窗口完全失效（安全事件恰好在失联时发生，用户无法查看）
  - 需要 daemon 实现额外 IPC 方法（`sieve.list_events` 等），增加 daemon 代码量
  - 分页 + 过滤在 IPC 层实现比 SQL WHERE 子句低效得多
- 估计成本：高（daemon 侧也需要改动）

### Option 2：SQLite.swift 只读直连 + DispatchSource file watch（本方案）
- 优点：
  - `Connection(path, readonly: true)` 打开，SQLite 本身支持多 reader 并发读（WAL 模式下读写不阻塞）
  - GUI 直接写 SQL 查询（WHERE / ORDER / LIMIT），filter 和搜索本地执行，延迟极低
  - IPC 失联不影响历史查看（完全独立）
  - `DispatchSource.makeFileSystemObjectSource(eventMask: [.write, .extend])` 监听 inode 变化，100ms 去抖后触发增量查询，实时刷新
  - SQLite.swift 已在第三方白名单内
- 缺点：
  - GUI 需要了解 audit.db schema；schema 升级时 GUI 需要 fail-soft 降级（data-model.md §2.4）
  - 直连文件依赖文件系统权限（`~/.sieve/audit.db` 的 owner read 权限），权限异常时需要引导修复
- 估计成本：低，SQLite.swift 封装完善，`readonly` 模式直接支持

### Option 3：混合方案：直连 + IPC 补充
- 优点：历史主路径直连，实时事件通过 IPC `event_notify` 补充
- 缺点：两路数据源合并复杂（去重、排序）；实际上 DispatchSource file watch 已经可以覆盖实时事件（audit.db append-only，新事件 = 新行）
- 估计成本：中，且复杂度不值得

## Decision

选择 Option 2：**SQLite.swift read-only 直连 + DispatchSource file watch**。

关键实现决策：

**连接模式**：
```swift
let db = try Connection("~/.sieve/audit.db", readonly: true)
```

**file watch**：
```swift
let source = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: fd,
    eventMask: [.write, .extend],
    queue: DispatchQueue(label: "com.sieve.gui.auditwatch", qos: .utility)
)
source.setEventHandler { [weak self] in
    // 100ms 去抖后触发增量查询
    self?.scheduleIncrementalQuery(debounce: 0.1)
}
source.resume()
```

**增量查询**：记录 `lastSeenId: Int64`，每次触发后执行 `SELECT ... WHERE id > lastSeenId`，不重复加载已有数据。

**schema 版本检查**：启动时 `PRAGMA user_version` 检查，未知版本时 `AppState.showAuditSchemaWarningBanner = true`，仍按已知字段查询（fail-soft）。

**append-only 保护**：daemon 端有数据库触发器阻止 UPDATE / DELETE（上游 data-model.md）；GUI read-only 连接本身也无法执行写操作，双重保护。

**`user_version` 已知范围**：v1（初始 schema）和 v2（含 `caller_pid` / `caller_exe`）。升级规则：v2 字段 GUI 尝试查询，失败时降级为空（见 data-model.md §2.4）。

## Consequences

**正面影响**：
- 历史窗口 filter / 搜索延迟极低（SQLite 本地查询，无网络往返）
- IPC 失联时历史窗口完全独立运行
- daemon 侧无需实现任何历史拉取 IPC 方法

**引入的新约束**：
- GUI 开发者必须了解 audit.db schema；每次 daemon 升级 schema 时，GUI 需要同步更新 fail-soft 处理逻辑
- DispatchSource file watch 在 macOS sandbox 下需要 `com.apple.security.files.user-selected.read-write` entitlement 的等价权限；验证 `~/.sieve/` 的访问不受 sandbox 阻碍
- 所有 SQL 查询必须加 `LIMIT`（防止历史窗口意外加载全表，PRD §8.1 内存约束）
- 禁止在 `@MainActor` 上执行 SQLite 查询（architecture.md §6 并发模型约束）；必须在后台队列读，用 `AsyncStream` 推回主线程

**后续需要做的事**：
- 实现 `AuditDBReader` 服务类，暴露 `AsyncStream<[EventRow]>` 接口
- 在 SPEC-004 §3 补充 SQL 查询的完整参数表
- 测试：schema v1/v2 升级路径；audit.db 不存在时的空状态处理；文件权限异常时的降级展示

## References

- 上游 [audit.db schema（data-model §4）](../../external/upstream-references.md#audit-db-schema)
- [`docs/design/data-model.md`](../data-model.md) §2（audit.db 只读视图）
- [`SPEC-004-history-window.md`](../../specs/SPEC-004-history-window.md)
- PRD §5.4.1（数据来源说明）、§8.1（历史窗口性能目标）
- [`docs/design/architecture.md`](../architecture.md) §6（并发模型）
