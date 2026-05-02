import Foundation
import os.log

/// 写 ~/.sieve/gui.log（追加，rotate 1MB），同时镜像到 os.Logger。
public actor GUILog {
    public static let shared = GUILog()
    private let osLog = Logger(subsystem: "com.sieve.gui", category: "gui-log")
    private let path: String = NSHomeDirectory() + "/.sieve/gui.log"
    private let rotatePath: String = NSHomeDirectory() + "/.sieve/gui.log.1"
    private let maxSize: Int = 1_000_000

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

        if FileManager.default.fileExists(atPath: path) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
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
        try? FileManager.default.removeItem(atPath: rotatePath)
        try? FileManager.default.moveItem(atPath: path, toPath: rotatePath)
    }
}
