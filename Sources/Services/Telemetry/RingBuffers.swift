import Foundation
import Combine

/// 实时事件 ring buffer（容量 1000）。来源：audit.db / IPC event_notify / GUILog。
@MainActor
public final class LiveEventsRingBuffer: ObservableObject {
    public static let shared = LiveEventsRingBuffer()

    public struct Entry: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let timestamp: Date
        public let source: Source
        public let level: Level
        public let category: String
        public let message: String

        public enum Source: String, Sendable { case audit, ipc, gui }
        public enum Level: String, Sendable { case info, warn, error }
    }

    public static let capacity: Int = 1000
    @Published public private(set) var entries: [Entry] = []
    @Published public var paused: Bool = false

    public func append(_ entry: Entry) {
        guard !paused else { return }
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    public func append(source: Entry.Source, level: Entry.Level, category: String, message: String) {
        append(.init(id: UUID(), timestamp: Date(), source: source, level: level, category: category, message: message))
    }

    public func filter(source: String, level: String, grep: String) -> [Entry] {
        entries.filter { e in
            (source == "all" || e.source.rawValue == source)
            && (level == "all" || e.level.rawValue == level)
            && (grep.isEmpty || e.message.localizedCaseInsensitiveContains(grep) || e.category.localizedCaseInsensitiveContains(grep))
        }
    }

    public func clear() { entries.removeAll() }
}

/// IPC 监视 ring buffer（容量 100）。仅记录消息元信息——params 列硬显「不展示」。
@MainActor
public final class IPCMonitorRingBuffer: ObservableObject {
    public static let shared = IPCMonitorRingBuffer()

    public struct Entry: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let timestamp: Date
        public let direction: Flow
        public let method: String
        public let messageId: String?
        public let bytes: Int

        public enum Flow: String, Sendable { case inbound, outbound }
    }

    public static let capacity: Int = 100

    @Published public private(set) var entries: [Entry] = []
    @Published public private(set) var handshakeCount: Int = 0
    @Published public private(set) var reconnectCount: Int = 0
    @Published public private(set) var inflightCount: Int = 0

    public func record(direction: Entry.Flow, method: String, messageId: String?, bytes: Int) {
        let e = Entry(id: UUID(), timestamp: Date(), direction: direction, method: method, messageId: messageId, bytes: bytes)
        entries.append(e)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
    }

    public func recordHandshake() { handshakeCount += 1 }
    public func recordReconnect() { reconnectCount += 1 }
    public func setInflight(_ n: Int) { inflightCount = n }
}
