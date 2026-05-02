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
    private let logger = Logger(subsystem: "com.sieve.gui", category: "audit-fs")

    public init(path: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    public func start() {
        stop()
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("audit-fs: open failed for \(self.path, privacy: .public)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.scheduleDebounce() }
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
}
