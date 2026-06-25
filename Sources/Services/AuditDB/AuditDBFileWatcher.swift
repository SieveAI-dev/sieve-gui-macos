import Foundation
import os.log

/// DispatchSource 监视 audit.db 文件变化。去抖 100ms 后回调。
public final class AuditDBFileWatcher: @unchecked Sendable {
    private let path: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.sieve.gui.audit-fs", qos: .utility)
    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: DispatchWorkItem?
    private var openRetries = 0
    private let maxOpenRetries = 10
    private let logger = Logger(subsystem: "com.sieve.gui", category: "audit-fs")

    public init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    public func start() {
        stop()
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // open 失败常见于 daemon 重建 audit.db 的瞬间（旧文件已 rename、新文件尚未就位）。
            // 有限次延迟重试，避免 watcher 在重建 gap 中静默永久失效（历史窗口停止刷新）。
            if openRetries < maxOpenRetries {
                openRetries += 1
                logger.warning("audit-fs: open failed for \(self.path, privacy: .public)，第 \(self.openRetries) 次重试")
                queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start() }
            } else {
                logger.error("audit-fs: open 连续失败 \(self.maxOpenRetries) 次，停止监视")
            }
            return
        }
        openRetries = 0
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let flags = self.source?.data ?? []
            if flags.contains(.delete) || flags.contains(.rename) {
                // 文件被删除/重命名（daemon 可能重建 audit.db）→ 当前 fd 绑定的旧 inode 失效，
                // 之后所有写入都监视不到。重启 watcher 重新 open 新文件，并主动触发一次刷新。
                self.scheduleRestart()
            } else {
                self.scheduleDebounce()
            }
        }
        src.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fd >= 0 {
                close(self.fd)
                self.fd = -1
            }
        }
        source = src
        src.resume()
    }

    public func stop() {
        debounceTask?.cancel()
        source?.cancel()
        source = nil
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        debounceTask = task
        queue.asyncAfter(deadline: .now() + 0.1, execute: task)
    }

    /// 文件被删除/重命名后重启监视：重新 `open` 新 inode 并拉一次最新数据。
    /// 延迟到下一个 queue 周期执行，避开「在 event handler 内 cancel 自身 source」。
    private func scheduleRestart() {
        debounceTask?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.start()     // start() 内部先 stop()（cancel 旧 source/fd）再 open 新文件
            self.onChange()  // 重建后主动刷新，避免漏掉重建瞬间已写入的事件
        }
        debounceTask = task
        queue.asyncAfter(deadline: .now() + 0.2, execute: task)
    }
}
