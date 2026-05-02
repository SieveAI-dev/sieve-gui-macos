import SwiftUI

public struct HistoryWindowView: View {
    @ObservedObject var viewModel: HistoryWindowViewModel
    @ObservedObject var appState: AppState

    public init(viewModel: HistoryWindowViewModel, appState: AppState) {
        self.viewModel = viewModel
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            if appState.auditSchemaWarning {
                schemaBanner
            }
            HistoryFilterBar(filter: $viewModel.filter, keyword: $viewModel.keywordInput, onApply: { viewModel.reload() })
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
        .onAppear { viewModel.start() }
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
                MaskedField(row.evidenceMetaJSON ?? "", style: .clearWhenUnlocked, isUnlocked: appState.isUnlocked && !appState.settings.historyMaskByDefault)
            }
        }
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
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
