import SwiftUI

public struct DebugWindowView: View {
    @ObservedObject var appState: AppState
    let ipcClient: IPCClient

    public init(appState: AppState, ipcClient: IPCClient) {
        self.appState = appState
        self.ipcClient = ipcClient
    }

    public var body: some View {
        TabView {
            LiveEventsTab(appState: appState)
                .tabItem { Label("实时事件", systemImage: "waveform") }
            RuleEvaluationTab(ipcClient: ipcClient)
                .tabItem { Label("规则评估", systemImage: "function") }
            IPCMonitorTab()
                .tabItem { Label("IPC 监视", systemImage: "antenna.radiowaves.left.and.right") }
            SystemStatusTab(ipcClient: ipcClient)
                .tabItem { Label("系统状态", systemImage: "speedometer") }
        }
        .frame(width: 960, height: 600)
    }
}

// MARK: - 实时事件

public struct LiveEventsTab: View {
    @ObservedObject var appState: AppState
    @ObservedObject var buffer: LiveEventsRingBuffer = .shared
    @State private var sourceFilter: String = "all"
    @State private var levelFilter: String = "all"
    @State private var grep: String = ""
    @State private var autoScroll: Bool = true

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("来源", selection: $sourceFilter) {
                    Text("全部").tag("all"); Text("audit").tag("audit"); Text("ipc").tag("ipc"); Text("gui").tag("gui")
                }.frame(width: 120)
                Picker("级别", selection: $levelFilter) {
                    Text("全部").tag("all"); Text("INFO").tag("info"); Text("WARN").tag("warn"); Text("ERROR").tag("error")
                }.frame(width: 120)
                TextField("grep…", text: $grep).textFieldStyle(.roundedBorder).frame(width: 180)
                Toggle("自动滚动", isOn: $autoScroll).toggleStyle(.checkbox)
                Text("\(buffer.entries.count)/\(LiveEventsRingBuffer.capacity)")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(buffer.paused ? "恢复" : "暂停") { buffer.paused.toggle() }
                Button("清空") { buffer.clear() }
            }
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(buffer.filter(source: sourceFilter, level: levelFilter, grep: grep)) { e in
                            row(e).id(e.id)
                        }
                    }
                }
                .onChange(of: buffer.entries.count) { _ in
                    if autoScroll, let last = buffer.entries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func row(_ e: LiveEventsRingBuffer.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(timeLabel(e.timestamp)).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
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
        switch s { case .audit: return .blue; case .ipc: return .purple; case .gui: return .gray }
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
    @State private var direction: String = "outbound"
    @State private var contentKind: String = "tool_use_input"
    @State private var payload: String = ""
    @State private var evaluating: Bool = false
    @State private var resultText: String = ""

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                Text(resultText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 160)
            .border(.gray.opacity(0.3))
        }
        .padding()
    }

    private func evaluate() {
        evaluating = true
        Task {
            do {
                let data = try await ipcClient.sendRequest(
                    id: UUID().uuidString,
                    method: "sieve.evaluate",
                    params: [
                        "direction": direction,
                        "content_kind": contentKind,
                        "payload": payload,
                        "source_agent": "claude-code"
                    ]
                )
                let pretty = String(data: (try? JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.prettyPrinted, .sortedKeys])) ?? data, encoding: .utf8) ?? ""
                await MainActor.run {
                    evaluating = false
                    resultText = pretty
                }
            } catch {
                await MainActor.run {
                    evaluating = false
                    resultText = "评估失败：\(error)"
                }
            }
        }
    }
}

// MARK: - IPC 监视

public struct IPCMonitorTab: View {
    @ObservedObject var monitor: IPCMonitorRingBuffer = .shared

    public var body: some View {
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
                    }
                }
            }
        }
        .padding()
    }

    private func row(_ e: IPCMonitorRingBuffer.Entry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: e.direction == .inbound ? "arrow.down" : "arrow.up")
                .foregroundStyle(e.direction == .inbound ? .blue : .purple)
                .frame(width: 16)
            Text(timeLabel(e.timestamp)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(e.method).frame(width: 220, alignment: .leading).lineLimit(1)
            Text(e.messageId ?? "—").foregroundStyle(.secondary).frame(width: 240, alignment: .leading).lineLimit(1)
            Text("\(e.bytes)B").foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
            // params 列硬显示「不展示」（SPEC-005 红线）
            Text("params: 不展示").foregroundStyle(.tertiary)
            Spacer()
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 4).padding(.vertical, 2)
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
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
                    let p = Process()
                    p.launchPath = "/usr/local/bin/sieve"
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
