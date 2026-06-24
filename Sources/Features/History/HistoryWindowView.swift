import SwiftUI

public struct HistoryWindowView: View {
    @ObservedObject var viewModel: HistoryWindowViewModel
    @ObservedObject var appState: AppState

    @State private var exportState: ExportState = .idle
    @State private var showExportFormatPicker: Bool = false
    @State private var selectedFormat: ExportFormat = .csv

    public init(viewModel: HistoryWindowViewModel, appState: AppState) {
        self.viewModel = viewModel
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            if appState.auditSchemaWarning {
                schemaBanner
            }
            HStack {
                HistoryFilterBar(filter: $viewModel.filter, keyword: $viewModel.keywordInput, onApply: { viewModel.reload() })
                exportButton
            }
            exportProgressBar
            Divider()
            HSplitView {
                listView
                    .frame(minWidth: 600)
                if let row = viewModel.selected {
                    InspectorPanelView(row: row, appState: appState)
                        .frame(width: 360)
                } else {
                    Text("从左侧选中一条记录查看详情")
                        .foregroundStyle(.secondary)
                        .frame(width: 360)
                }
            }
        }
        .frame(width: 1080, height: 660)
        .onAppear {
            viewModel.start()
            appState.setAuditSchemaWarning(viewModel.schemaWarning)
        }
        .onChange(of: viewModel.schemaWarning) { warn in
            appState.setAuditSchemaWarning(warn)
        }
        .confirmationDialog("选择导出格式", isPresented: $showExportFormatPicker) {
            Button("CSV") { startExport(format: .csv) }
            Button("NDJSON") { startExport(format: .ndjson) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("历史记录将强制脱敏，不含 evidence 原文。")
        }
    }

    @ViewBuilder
    private var exportButton: some View {
        if case .running = exportState {
            Button("取消导出") {
                Task { await HistoryExporter.shared.cancel() }
                exportState = .idle
            }
            .buttonStyle(.bordered)
            .padding(.trailing, 8)
        } else {
            Button("导出…") { showExportFormatPicker = true }
                .buttonStyle(.bordered)
                .padding(.trailing, 8)
                .disabled(viewModel.rows.isEmpty)
        }
    }

    @ViewBuilder
    private var exportProgressBar: some View {
        if case .running(let p) = exportState {
            VStack(spacing: 0) {
                ProgressView(value: p)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .background(Color.accentColor.opacity(0.06))
        } else if case .done(let url) = exportState {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("已导出：\(url.lastPathComponent)")
                    .font(.caption)
                Spacer()
                Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: "") }
                    .font(.caption)
                Button(action: { exportState = .idle }) {
                    Image(systemName: "xmark").font(.caption)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.06))
        } else if case .failed(let msg) = exportState {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(msg).font(.caption)
                Spacer()
                Button(action: { exportState = .idle }) {
                    Image(systemName: "xmark").font(.caption)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.06))
        }
    }

    private var schemaBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text("audit.db schema 版本未知。已知字段继续展示。").font(.caption)
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.08))
    }

    private var listView: some View {
        Table(viewModel.rows, selection: Binding(get: { viewModel.selected.map(\.id) }, set: { id in
            if let id { viewModel.selected = viewModel.rows.first { $0.id == id } }
            else { viewModel.selected = nil }
        })) {
            TableColumn("Time") { row in Text(timeLabel(row.createdAt)).font(.caption) }
                .width(min: 80, ideal: 84)
            TableColumn("Dir") { row in DirectionBadge(row.direction) }
                .width(32)
            TableColumn("Sev") { row in SeverityChip(row.severity) }
                .width(min: 60, ideal: 80)
            TableColumn("Rule") { row in Text(row.ruleId).font(.system(.caption, design: .monospaced)) }
                .width(min: 100, ideal: 130)
            TableColumn("Action") { row in Text(row.disposition).font(.caption) }
                .width(min: 60, ideal: 80)
            TableColumn("Detail") { row in
                MaskedField(row.evidenceMetaJSON ?? "", style: .clearWhenUnlocked, isUnlocked: historyContentUnlocked)
                    .onAppear {
                        // 触底翻页：末行 cell 出现即拉下一页（SwiftUI Table 无原生触底回调）。
                        if row.id == viewModel.rows.last?.id { viewModel.loadMore() }
                    }
            }
        }
    }

    /// 列表与 Inspector 统一的"解锁后是否显示明文"判定：
    /// 已 Touch ID 解锁且未开启「历史默认脱敏」。两处必须同源，避免明文判定矛盾。
    private var historyContentUnlocked: Bool {
        HistoryMaskPolicy.contentUnlocked(appState)
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private func startExport(format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = "sieve-history-\(Int(Date().timeIntervalSince1970)).\(format.fileExtension)"
        panel.title = "导出历史记录（强制脱敏）"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let rows = viewModel.rows
        exportState = .running(progress: 0)
        Task {
            await HistoryExporter.shared.export(rows: rows, format: format, to: url) { state in
                Task { @MainActor in
                    exportState = state
                }
            }
        }
    }
}

public struct HistoryFilterBar: View {
    @Binding var filter: AuditFilter
    @Binding var keyword: String
    let onApply: () -> Void

    public var body: some View {
        HStack(spacing: 8) {
            TextField("搜索 rule_id…", text: $keyword)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            Picker("方向", selection: Binding(get: { filter.direction?.rawValue ?? "all" }, set: { v in
                filter.direction = (v == "all") ? nil : Direction(rawValue: v); onApply()
            })) {
                Text("全部").tag("all")
                Text("Inbound").tag("inbound")
                Text("Outbound").tag("outbound")
            }
            .frame(width: 120)
            Picker("严重度", selection: Binding(get: { filter.severity?.rawValue ?? "all" }, set: { v in
                filter.severity = (v == "all") ? nil : Severity(rawValue: v); onApply()
            })) {
                Text("全部").tag("all")
                ForEach(Severity.allCases, id: \.rawValue) { s in
                    Text(s.rawValue.capitalized).tag(s.rawValue)
                }
            }
            .frame(width: 120)
            Spacer()
        }
        .padding(8)
    }
}
