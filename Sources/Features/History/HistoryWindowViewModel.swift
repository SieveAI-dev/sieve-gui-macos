import Foundation
import Combine

@MainActor
public final class HistoryWindowViewModel: ObservableObject {
    @Published public private(set) var rows: [AuditEventRow] = []
    @Published public var filter: AuditFilter = .init()
    @Published public var keywordInput: String = ""
    @Published public private(set) var loading: Bool = false
    @Published public var selected: AuditEventRow?

    private let reader: AuditDBReader
    private var lastSeenId: Int64 = 0
    private let maxKept: Int = 200
    private var keywordCancellable: AnyCancellable?

    public init(reader: AuditDBReader) {
        self.reader = reader
        keywordCancellable = $keywordInput
            .removeDuplicates()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] kw in
                self?.filter.keyword = kw.isEmpty ? nil : kw
                self?.reload()
            }
    }

    public func start() {
        do { try reader.open() } catch { /* fail-soft */ }
        reload()
        reader.startWatching { [weak self] in
            Task { @MainActor in self?.appendIncremental() }
        }
    }

    public func reload() {
        loading = true
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
        vm.loading = false
    }

    public func loadMore() {
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
