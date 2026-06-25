import Foundation
import Combine

// MARK: - Notification 名称

public extension Notification.Name {
    /// purge_history 成功后广播：History 窗口监听后重新 reload。
    static let sieveHistoryPurged = Notification.Name("com.sieve.gui.historyPurged")
}

@MainActor
public final class HistoryWindowViewModel: ObservableObject {
    @Published public private(set) var rows: [AuditEventRow] = []
    @Published public var filter: AuditFilter = .init()
    @Published public var keywordInput: String = ""
    @Published public private(set) var loading: Bool = false
    @Published public var selected: AuditEventRow?
    /// reader 打开后回写的 schema 警告位（基于实际 PRAGMA user_version，非 hello 推送值）。
    /// View 观察此位写入 AppState.setAuditSchemaWarning 驱动 banner。
    @Published public private(set) var schemaWarning: Bool = false
    /// 列表已无更多数据（loadMore 返回空），触底回调据此停止继续翻页。
    @Published public private(set) var reachedEnd: Bool = false

    private let reader: AuditDBReader
    private var lastSeenId: Int64 = 0
    private let maxKept: Int = 200
    private var keywordCancellable: AnyCancellable?
    private var purgeObserverToken: AnyCancellable?

    public init(reader: AuditDBReader) {
        self.reader = reader
        keywordCancellable = $keywordInput
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] kw in
                self?.filter.keyword = kw.isEmpty ? nil : kw
                self?.reload()
            }
        // 监听清空历史通知 → 刷新列表（用 Combine publisher 管理生命周期，避免 deinit @MainActor 隔离问题）
        purgeObserverToken = NotificationCenter.default
            .publisher(for: .sieveHistoryPurged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.lastSeenId = 0
                self?.reload()
            }
    }

    public func start() {
        do { try reader.open() } catch { /* fail-soft */ }
        // reader 打开后用实际 PRAGMA user_version 判定 schema 警告（fail-soft，SPEC-004 §异常）。
        // 即便 open() 抛错（未知/损坏 schema）也回写，schemaVersion 保持默认 0 → 未知 → 告警。
        schemaWarning = reader.schemaWarning
        reload()
        reader.startWatching { [weak self] in
            Task { @MainActor in self?.appendIncremental() }
        }
    }

    public func reload() {
        loading = true
        reachedEnd = false
        let f = filter
        let reader = self.reader
        Task.detached {
            let result = reader.recentEvents(limit: 50, offset: 0, filter: f)
            await Self.applyReload(result, viewModel: self)
        }
    }

    @MainActor
    private static func applyReload(_ rows: [AuditEventRow], viewModel: HistoryWindowViewModel?) {
        guard let vm = viewModel else { return }
        vm.rows = rows
        vm.lastSeenId = rows.first?.id ?? 0
        vm.reachedEnd = rows.count < 50
        vm.loading = false
    }

    /// 触底翻页：Table 末行 .onAppear 触发。重入/已到底/正加载时直接跳过。
    public func loadMore() {
        guard !loading, !reachedEnd else { return }
        loading = true
        let offset = rows.count
        let f = filter
        let reader = self.reader
        Task.detached {
            let more = reader.recentEvents(limit: 50, offset: offset, filter: f)
            await Self.applyAppend(more, viewModel: self)
        }
    }

    @MainActor
    private static func applyAppend(_ more: [AuditEventRow], viewModel: HistoryWindowViewModel?) {
        guard let vm = viewModel else { return }
        vm.rows.append(contentsOf: more)
        if vm.rows.count > vm.maxKept { vm.rows.removeFirst(vm.rows.count - vm.maxKept) }
        vm.reachedEnd = more.count < 50
        vm.loading = false
    }

    /// 导出用：按当前 filter 从 reader 分页拉取**全部**行（不受 UI 内存窗口 maxKept=200 限制）。
    /// UI 列表只保留滑动窗口（翻页后早期行已被 removeFirst 丢弃），导出必须重新走全量分页查询，
    /// 否则用户拿到的是残缺且不可预测的子集。在后台 reader queue 分页，避免阻塞主线程。
    public func fetchAllForExport() async -> [AuditEventRow] {
        let f = filter
        let reader = self.reader
        return await Task.detached {
            var all: [AuditEventRow] = []
            let page = 200
            var offset = 0
            while true {
                let batch = reader.recentEvents(limit: page, offset: offset, filter: f)
                if batch.isEmpty { break }
                all.append(contentsOf: batch)
                if batch.count < page { break }
                offset += page
            }
            return all
        }.value
    }

    private func appendIncremental() {
        let from = lastSeenId
        let reader = self.reader
        let maxKept = self.maxKept
        Task.detached {
            let added = reader.incrementalEvents(sinceId: from, limit: 50)
            guard !added.isEmpty else { return }
            await Self.applyIncremental(added, fromId: from, maxKept: maxKept, viewModel: self)
        }
    }

    @MainActor
    private static func applyIncremental(_ added: [AuditEventRow], fromId: Int64, maxKept: Int, viewModel: HistoryWindowViewModel?) {
        guard let vm = viewModel else { return }
        vm.rows.insert(contentsOf: added.reversed(), at: 0)
        vm.lastSeenId = added.last?.id ?? fromId
        if vm.rows.count > maxKept { vm.rows.removeLast(vm.rows.count - maxKept) }
    }
}
