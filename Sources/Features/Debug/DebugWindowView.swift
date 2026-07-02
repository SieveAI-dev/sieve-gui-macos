import SwiftUI
import Combine

public struct DebugWindowView: View {
    @ObservedObject var appState: AppState
    let ipcClient: IPCClient
    @EnvironmentObject private var replayStore: DebugReplayStore
    @State private var selectedTab: DebugTab = .liveEvents

    public init(appState: AppState, ipcClient: IPCClient) {
        self.appState = appState
        self.ipcClient = ipcClient
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            LiveEventsTab(appState: appState)
                .tabItem { Label("实时事件", systemImage: "waveform") }
                .tag(DebugTab.liveEvents)
            RuleEvaluationTab(ipcClient: ipcClient)
                .environmentObject(replayStore)
                .tabItem { Label("规则评估", systemImage: "function") }
                .tag(DebugTab.ruleEvaluation)
            IPCMonitorTab(ipcClient: ipcClient)
                .tabItem { Label("IPC 监视", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(DebugTab.ipcMonitor)
            SystemStatusTab(ipcClient: ipcClient)
                .tabItem { Label("系统状态", systemImage: "speedometer") }
                .tag(DebugTab.systemStatus)
        }
        .frame(width: 960, height: 600)
        .onAppear {
            if replayStore.prefilledPrompt != nil {
                selectedTab = .ruleEvaluation
            }
        }
        .onChange(of: replayStore.prefilledPrompt) { prompt in
            if prompt != nil {
                selectedTab = .ruleEvaluation
            }
        }
    }
}

private enum DebugTab: Hashable {
    case liveEvents
    case ruleEvaluation
    case ipcMonitor
    case systemStatus
}

// MARK: - 实时事件

public struct LiveEventsTab: View {
    @ObservedObject var appState: AppState
    @ObservedObject var buffer: LiveEventsRingBuffer = .shared
    @State private var sourceFilter: String = "all"
    @State private var levelFilter: String = "all"
    /// 用户正在输入的 grep 文本（原始值，未去抖）
    @State private var grepInput: String = ""
    /// 实际用于过滤的 grep 文本（200ms 去抖后生效）
    @State private var grepDebounced: String = ""
    @State private var autoScroll: Bool = true
    /// 200ms 去抖 DispatchWorkItem
    @State private var debounceWork: DispatchWorkItem?

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("来源", selection: $sourceFilter) {
                    Text("全部").tag("all"); Text("audit").tag("audit"); Text("ipc").tag("ipc"); Text("gui").tag("gui")
                }.frame(width: 120)
                Picker("级别", selection: $levelFilter) {
                    Text("全部").tag("all"); Text("INFO").tag("info"); Text("WARN").tag("warn"); Text("ERROR").tag("error")
                }.frame(width: 120)
                TextField("grep…", text: $grepInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onChange(of: grepInput) { newVal in
                        debounceWork?.cancel()
                        let work = DispatchWorkItem {
                            grepDebounced = newVal
                        }
                        debounceWork = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                    }
                Toggle("自动滚动", isOn: $autoScroll).toggleStyle(.checkbox)
                Text("\(buffer.entries.count)/\(LiveEventsRingBuffer.capacity)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                // 暂停：只冻结 UI 快照，ring buffer 继续记录
                Button(buffer.paused ? "恢复" : "暂停") { buffer.paused.toggle() }
                    .help(buffer.paused ? "恢复滚动（ring buffer 一直在记录）" : "暂停滚动查看快照（ring buffer 继续记录）")
                Button("清空") { buffer.clear() }
            }
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(buffer.filter(source: sourceFilter, level: levelFilter, grep: grepDebounced)) { e in
                            row(e).id(e.id)
                        }
                    }
                }
                .onChange(of: buffer.entries.count) { _ in
                    // 暂停时不自动滚动（快照视图）
                    if autoScroll && !buffer.paused, let last = buffer.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func row(_ e: LiveEventsRingBuffer.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timeLabel(e.timestamp)).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(e.source.rawValue).foregroundStyle(sourceColor(e.source)).frame(width: 50, alignment: .leading)
            Text(e.level.rawValue.uppercased()).foregroundStyle(levelColor(e.level)).frame(width: 50, alignment: .leading)
            Text(e.category).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(e.message)
            Spacer()
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 8).padding(.vertical, 2)
    }

    private func sourceColor(_ s: LiveEventsRingBuffer.Entry.Source) -> Color {
        switch LiveEventsRingBuffer.sourceColorToken(s) {
        case .blue: return .blue
        case .orange: return .orange
        case .green: return .green
        }
    }
    private func levelColor(_ l: LiveEventsRingBuffer.Entry.Level) -> Color {
        switch l { case .info: return .secondary; case .warn: return .orange; case .error: return .red }
    }
    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: d)
    }
}

// MARK: - 规则评估

public struct RuleEvaluationTab: View {
    let ipcClient: IPCClient
    @EnvironmentObject private var replayStore: DebugReplayStore
    @State private var direction: String = "outbound"
    @State private var contentKind: String = "tool_use_input"
    @State private var payload: String = ""
    @State private var evaluating: Bool = false
    /// 结构化评估结果（用 EvaluateResult DTO 解码）。
    /// 红线：matched_pattern_summary 对非 critical_lock 规则会回填原 payload 片段
    /// （daemon handle_evaluate：`matched N bytes …: "<snippet>"`），故视同 evidence，
    /// 命中片段走 MaskedField，且切 Tab / 关窗时整体清空（不常驻内存）。
    @State private var result: EvaluationOutcome?
    @State private var replayBannerVisible: Bool = false

    /// View 层评估产物。仅持有结构化 meta + 视作 evidence 的 summary；不保留 daemon 响应原 JSON。
    /// EvaluateResult 仅 Decodable/Sendable（非 Equatable），故本枚举不加 Equatable。
    enum EvaluationOutcome {
        case ok(EvaluateResult)
        case failure(String)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if replayBannerVisible {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.left.circle.fill").foregroundStyle(Color.accentColor)
                    Text("已从历史记录填入 payload").font(.caption)
                    Spacer()
                    Button(action: { replayBannerVisible = false }) {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Picker("方向", selection: $direction) {
                    Text("Outbound").tag("outbound"); Text("Inbound").tag("inbound")
                }.frame(width: 160)
                Picker("内容类型", selection: $contentKind) {
                    Text("text").tag("text"); Text("tool_use_input").tag("tool_use_input"); Text("sse_chunk").tag("sse_chunk")
                }.frame(width: 200)
            }
            TextEditor(text: $payload)
                .font(.system(.body, design: .monospaced))
                .frame(maxHeight: .infinity)
                .border(.gray.opacity(0.3))
            HStack {
                Text("\(payload.utf8.count) / 65536 bytes")
                    .font(.caption)
                    .foregroundStyle(payload.utf8.count > 65536 ? .red : .secondary)
                Spacer()
                Button(evaluating ? "评估中…" : "评估") {
                    evaluate()
                }
                .disabled(evaluating || payload.utf8.count > 65536 || payload.isEmpty)
            }
            ScrollView {
                resultView
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 200)
            .border(.gray.opacity(0.3))
        }
        .padding()
        .onAppear { applyPrefilledIfNeeded() }
        .onChange(of: replayStore.prefilledPrompt) { _ in applyPrefilledIfNeeded() }
        // 切 Tab / 关窗时清空：评估结果含可能回填的命中片段，不常驻内存（硬约束 #3）。
        .onDisappear { result = nil }
    }

    @ViewBuilder
    private var resultView: some View {
        switch result {
        case .none:
            Text("尚未评估")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case let .some(.failure(message)):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case let .some(.ok(eval)):
            if eval.matches.isEmpty {
                Label("未命中任何规则", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
                noMatchSummary(eval)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(eval.matches) { match in
                        matchRow(match)
                    }
                    noMatchSummary(eval)
                }
            }
        }
    }

    @ViewBuilder
    private func noMatchSummary(_ eval: EvaluateResult) -> some View {
        if let noMatch = eval.noMatch, !noMatch.isEmpty {
            Text("未命中（抽样）：\(noMatch.joined(separator: ", "))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    private func matchRow(_ match: EvaluateResult.Match) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.red)
                if let sev = match.severity {
                    SeverityChip(sev)
                } else {
                    Text("严重度未知").font(.caption2).foregroundStyle(.secondary)
                }
                Text(match.ruleId)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                Text(match.ruleKind)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 8) {
                Text("disposition: \(match.disposition)")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("would: \(match.wouldDecision)")
                    .font(.caption2).foregroundStyle(.secondary)
                if let triggered = match.fieldsTriggered, !triggered.isEmpty {
                    Text("fields: \(triggered.joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            // 红线：matched_pattern_summary 对非 critical_lock 规则可能回填原 payload 片段，
            // 视同 evidence，走 MaskedField（locked 全脱敏），禁止裸 Text。
            if let summary = match.matchedPatternSummary, !summary.isEmpty {
                HStack(spacing: 6) {
                    Text("命中摘要")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    MaskedField(summary, style: .fullMask, isUnlocked: false, monospaced: true)
                }
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func applyPrefilledIfNeeded() {
        guard let prompt = replayStore.consumePrefilled() else { return }
        payload = prompt
        replayBannerVisible = true
    }

    private func evaluate() {
        evaluating = true
        Task {
            do {
                let data = try await ipcClient.sendRequest(
                    id: UUID().uuidString,
                    method: "sieve.evaluate",
                    params: EvaluateParams(
                        direction: direction,
                        contentKind: contentKind,
                        payload: payload,
                        sourceAgent: "claude"
                    )
                )
                let outcome = Self.decodeResult(from: data)
                await MainActor.run {
                    evaluating = false
                    result = outcome
                }
            } catch {
                await MainActor.run {
                    evaluating = false
                    // 不回显 daemon 原始响应；仅展示本地错误类型描述。
                    result = .failure("评估失败：\(error)")
                }
            }
        }
    }

    /// 把 IPCClient 已解包出的 `result` 对象解码为 EvaluateResult DTO。
    /// 注意：sendRequest 返回的是 JSON-RPC `result` 字段本身（见 IPCMessage.parse），
    /// 不含外层 envelope，故此处直接解 EvaluateResult。
    /// 不再 pretty-print 整块 daemon JSON（旧实现把原响应常驻 @State，泄露命中片段）。
    static func decodeResult(from data: Data) -> EvaluationOutcome {
        do {
            let result = try JSONDecoder().decode(EvaluateResult.self, from: data)
            return .ok(result)
        } catch {
            // DTO 解码失败（如 severity 出现枚举外取值）时只报结构错误，
            // 绝不回退到裸 dump 原始 JSON（会泄露命中片段）。
            return .failure("响应结构无法解析为 EvaluateResult")
        }
    }
}

// MARK: - IPC 监视

public struct IPCMonitorTab: View {
    let ipcClient: IPCClient
    @ObservedObject var monitor: IPCMonitorRingBuffer = .shared
    /// 当前选中行（点击展开详情面板）
    @State private var selectedEntry: IPCMonitorRingBuffer.Entry?
    /// 每秒刷新 inflight 在途数（inflight 是 actor 上的 async 读取）
    private let inflightTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(ipcClient: IPCClient) {
        self.ipcClient = ipcClient
    }

    public var body: some View {
        HSplitView {
            // 左侧：消息列表
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    StatCard(title: "握手次数", value: "\(monitor.handshakeCount)")
                    StatCard(title: "重连次数", value: "\(monitor.reconnectCount)")
                    StatCard(title: "Inflight", value: "\(monitor.inflightCount)")
                }
                Divider()
                HStack {
                    Text("消息流").font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(monitor.entries.count)/\(IPCMonitorRingBuffer.capacity)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(monitor.entries.reversed()) { e in
                            row(e)
                                .background(selectedEntry?.id == e.id ? Color.accentColor.opacity(0.12) : Color.clear)
                                .onTapGesture { selectedEntry = (selectedEntry?.id == e.id) ? nil : e }
                        }
                    }
                }
            }
            .padding()
            .frame(minWidth: 500)

            // 右侧：详情面板
            if let entry = selectedEntry {
                IPCEntryDetailPanel(entry: entry)
                    .frame(minWidth: 280, idealWidth: 320)
            } else {
                Text("点击左侧行查看详情")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 280, idealWidth: 320)
            }
        }
        .onAppear { refreshInflight() }
        .onReceive(inflightTimer) { _ in refreshInflight() }
    }

    /// 从 IPCClient 拉取当前在途数写入 ring buffer。inflight 是 actor 上的 async 读取，
    /// 读完跳回 MainActor 更新 @Published。
    private func refreshInflight() {
        Task { @MainActor in
            let n = await ipcClient.inflightCount
            monitor.setInflight(n)
        }
    }

    private func row(_ e: IPCMonitorRingBuffer.Entry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: e.direction == .inbound ? "arrow.down" : "arrow.up")
                .foregroundStyle(e.direction == .inbound ? .blue : .purple)
                .frame(width: 16)
            Text(timeLabel(e.timestamp)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(e.method).frame(width: 220, alignment: .leading).lineLimit(1)
            Text(e.messageId ?? "—").foregroundStyle(.secondary).frame(width: 200, alignment: .leading).lineLimit(1)
            Text("\(e.bytes)B").foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
            // params 硬红线：永不展示（SPEC-005）
            Text("params: 不展示").foregroundStyle(.tertiary)
            Spacer()
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 4).padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: d)
    }
}

/// IPC 条目详情面板（展示 method / id / bytes / timestamp，永不展示 params）
public struct IPCEntryDetailPanel: View {
    let entry: IPCMonitorRingBuffer.Entry

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("消息详情").font(.headline)
            Divider()
            detailRow(label: "Method", value: entry.method)
            detailRow(label: "ID", value: entry.messageId ?? "—")
            detailRow(label: "Bytes", value: "\(entry.bytes) B")
            detailRow(label: "Timestamp", value: timeLabel(entry.timestamp))
            detailRow(label: "Direction", value: entry.direction == .inbound ? "↓ inbound" : "↑ outbound")
            Divider()
            // 硬红线：params 永不展示
            HStack(spacing: 6) {
                Image(systemName: "eye.slash").foregroundStyle(.secondary)
                Text("params 不展示（SPEC-005 红线）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func timeLabel(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}

public struct SystemStatusTab: View {
    let ipcClient: IPCClient
    @State private var lastFetch: Date?

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                StatCard(title: "P99 latency", value: "— ms")
                StatCard(title: "tasks", value: "—")
                StatCard(title: "1h hits", value: "—")
                StatCard(title: "audit.db", value: "—")
            }
            Divider()
            Text("文件系统权限").font(.headline)
            FileSystemStatusList()
            Spacer()
            HStack {
                Spacer()
                Button("运行 sieve doctor…") {
                    guard let bin = SieveBinaryLocator.resolve() else { return }
                    let p = Process()
                    p.launchPath = bin
                    p.arguments = ["doctor"]
                    try? p.run()
                }
            }
        }
        .padding()
        .onAppear { refresh() }
    }

    private func refresh() {
        Task {
            _ = try? await ipcClient.sendRequest(id: UUID().uuidString, method: "sieve.health")
            await MainActor.run { lastFetch = Date() }
        }
    }
}

public struct StatCard: View {
    let title: String
    let value: String
    public var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

public struct FileSystemStatusList: View {
    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("~/.sieve/", expected: "0700")
            row("~/.sieve/ipc.sock", expected: "0600")
            row("~/.sieve/audit.db", expected: "0600")
            row("~/.sieve/gui.log", expected: "0600")
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func row(_ path: String, expected: String) -> some View {
        let actualPath = (path as NSString).expandingTildeInPath
        let attrs = try? FileManager.default.attributesOfItem(atPath: actualPath)
        let perm = attrs?[.posixPermissions] as? Int
        let permStr = perm.map { String($0, radix: 8) } ?? "—"
        let ok = perm.map { String($0, radix: 8) == expected } ?? false
        return HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(path)
            Spacer()
            Text("got \(permStr) / want \(expected)").foregroundStyle(.secondary)
        }
    }
}
