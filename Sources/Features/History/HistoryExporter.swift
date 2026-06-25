import Foundation

// ExportFormat 定义在 Sources/Models/HistoryExportFormatter.swift

/// 导出进度状态
public enum ExportState: Sendable {
    case idle
    case running(progress: Double)   // 0.0 ... 1.0
    case done(url: URL)
    case failed(String)
}

/// 强制脱敏导出器 actor。
/// 实际格式化逻辑委托给 HistoryExportFormatter（Models 层，可单元测试）。
public actor HistoryExporter {
    public static let shared = HistoryExporter()

    private var currentTask: Task<Void, Never>?

    /// 发起导出。已有进行中的任务会被取消后重新开始。
    public func export(rows: [AuditEventRow], format: ExportFormat, to url: URL, onUpdate: @escaping @Sendable (ExportState) -> Void) {
        currentTask?.cancel()
        currentTask = Task {
            await runExport(rows: rows, format: format, to: url, onUpdate: onUpdate)
        }
    }

    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    private func runExport(rows: [AuditEventRow], format: ExportFormat, to url: URL, onUpdate: @escaping @Sendable (ExportState) -> Void) async {
        let total = rows.count
        guard total > 0 else {
            onUpdate(.failed("无数据可导出"))
            return
        }

        let formatter = HistoryExportFormatter(format: format)
        var lines: [String] = []
        if format == .csv {
            lines.append("id,created_at,direction,severity,rule_id,disposition,user_choice,request_id")
        }

        for (i, row) in rows.enumerated() {
            if Task.isCancelled { return }

            lines.append(formatter.formatLine(row: row))

            // 每 20 行汇报一次进度
            if i % 20 == 0 {
                let progress = Double(i + 1) / Double(total)
                onUpdate(.running(progress: progress))
                await Task.yield()
            }
        }

        if Task.isCancelled { return }

        let output = lines.joined(separator: "\n") + "\n"
        do {
            // String.write(atomically:) 本身就是「写临时文件 → 原子 rename」，无需再手工套一层
            // .tmp + replaceItemAt（旧实现的 replaceItemAt 还用 try? 吞错，失败仍报 .done 且残留 tmp）。
            try output.write(to: url, atomically: true, encoding: .utf8)
            onUpdate(.done(url: url))
        } catch {
            onUpdate(.failed("写文件失败：\(error.localizedDescription)"))
        }
    }
}
