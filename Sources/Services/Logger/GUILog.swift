import Foundation
import os.log

/// 写 ~/.sieve/gui.log（追加，rotate 1MB），同时镜像到 os.Logger。
///
/// 硬约束 #8 适用边界澄清：#8 的「atomic rename」针对**整文件替换**语义
/// （preset 缓存 / 用户设置——它们用 `Data.write(options: .atomic)` 经临时文件 + rename 满足）。
/// 而 append-only 日志的正文逐行 rename 整文件不现实（每行重写全文件，O(n²) 开销且无意义）。
/// 等价安全保证由 **POSIX O_APPEND 原子追加** 提供：内核对以 `O_APPEND` 打开的 fd 的单次
/// `write(2)` 保证「seek 到末尾 + 写入」是原子的，多进程并发也不会交错或覆盖
/// （POSIX.1 / `man 2 write`）。本 actor 持有一个持久 `O_APPEND` fd，避免每次 open/seek/close
/// 之间的竞态窗口；rotate 走 `moveItem`（filesystem rename，本身 atomic）后重开 fd 指向新文件。
public actor GUILog {
    public static let shared = GUILog()
    private let osLog = Logger(subsystem: "com.sieve.gui", category: "gui-log")
    private let path: String = NSHomeDirectory() + "/.sieve/gui.log"
    private let rotatePath: String = NSHomeDirectory() + "/.sieve/gui.log.1"
    private let maxSize: Int = 1_000_000

    /// 持久的 O_APPEND fd 句柄。惰性打开，rotate 后置 nil 以触发重开。
    /// `closeOnDealloc: true` 保证 FileHandle 析构时关闭底层 fd，无需手写 deinit
    /// （actor deinit 为 nonisolated，访问 isolated 存储在严格并发下会告警）。
    private var handle: FileHandle?

    public func info(_ msg: String, category: String = "general") {
        write(level: "INFO", category: category, message: msg)
        osLog.notice("\(msg, privacy: .public)")
        Self.tail?(.init(level: "INFO", category: category, message: msg))
    }

    public func warn(_ msg: String, category: String = "general") {
        write(level: "WARN", category: category, message: msg)
        osLog.warning("\(msg, privacy: .public)")
        Self.tail?(.init(level: "WARN", category: category, message: msg))
    }

    public func error(_ msg: String, category: String = "general") {
        write(level: "ERROR", category: category, message: msg)
        osLog.error("\(msg, privacy: .public)")
        Self.tail?(.init(level: "ERROR", category: category, message: msg))
    }

    public struct Tail: Sendable {
        public let level: String
        public let category: String
        public let message: String
    }

    /// 由调用方注册（典型实现：将日志推到 LiveEventsRingBuffer 的 main actor 队列）。
    public nonisolated(unsafe) static var tail: (@Sendable (Tail) -> Void)?

    private func write(level: String, category: String, message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) [\(level)] [\(category)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        ensureParent()
        rotateIfNeeded()

        guard let fh = currentHandle() else { return }
        // O_APPEND 模式下单次 write(2) 原子追加：内核保证「定位到末尾 + 写入」不可分割，
        // 无需显式 seekToEnd，也不与其它写者交错（见类型注释「硬约束 #8 适用边界」）。
        try? fh.write(contentsOf: data)
    }

    /// 返回持久的 O_APPEND fd 句柄；首次调用或 rotate 后惰性创建并设 0o600 权限。
    private func currentHandle() -> FileHandle? {
        if let h = handle { return h }

        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return nil }
        // 防御 umask 把权限放宽：显式收敛到仅属主可读写。
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        handle = h
        return h
    }

    private func ensureParent() {
        let parent = (path as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: parent) {
            try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int, size >= maxSize else { return }
        // 关闭并丢弃旧 fd：rename 后旧 fd 仍指向已搬走的 inode，继续写会写进 .log.1。
        // 置 nil 触发下次写入惰性重开指向新 gui.log。
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(atPath: rotatePath)
        try? FileManager.default.moveItem(atPath: path, toPath: rotatePath)
    }
}
