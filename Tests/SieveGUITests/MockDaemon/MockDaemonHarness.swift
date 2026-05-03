import Foundation
@testable import SieveGUICore

/// Mock daemon — 监听 Unix Domain Socket（POSIX），按 IPC 协议握手，
/// 供 IPCClient 集成测试使用。每次测试独立创建实例，socket 路径 tempfile 隔离。
final class MockDaemonHarness: @unchecked Sendable {

    // MARK: - 公开

    let socketPath: String

    // MARK: - 私有

    private var serverFd: Int32 = -1
    private var clientFd: Int32 = -1
    private var acceptedCount: Int = 0  // 历史 accept 总数，用于 waitForNewConnection
    private let lock = NSLock()
    private var receivedLines: [Data] = []

    private struct Waiter {
        let id: Int
        let cont: CheckedContinuation<Data, Error>
        let workItem: DispatchWorkItem
    }
    private var waiters: [Waiter] = []
    private var waiterSeq: Int = 0

    private let queue = DispatchQueue(label: "com.sieve.test.mock-daemon", qos: .userInitiated)

    // MARK: - 初始化

    init() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".sock")
        self.socketPath = tmp.path
    }

    deinit { stop() }

    // MARK: - 生命周期

    func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOBUFS) }
        serverFd = fd

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { dest in
            for i in 0..<min(pathBytes.count, dest.count) {
                dest[i] = UInt8(bitPattern: pathBytes[i])
            }
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOBUFS)
        }
        guard listen(fd, 5) == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOBUFS)
        }
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        let sfd = serverFd
        let cfd = clientFd
        serverFd = -1
        clientFd = -1
        if sfd >= 0 { Darwin.close(sfd) }
        if cfd >= 0 { Darwin.close(cfd) }
        try? FileManager.default.removeItem(atPath: socketPath)
        cancelAllWaiters()
    }

    /// 断开当前客户端连接（模拟 daemon 崩溃/重启）
    func disconnectClient() {
        let cfd = clientFd
        clientFd = -1
        if cfd >= 0 { Darwin.close(cfd) }
    }

    // MARK: - 发送 API

    /// 发送 sieve.hello（全 7 字段）
    func sendHello(
        protocolVersion: String = "v2",
        daemonVersion: String = "0.9.0-test",
        daemonBootId: String = UUID().uuidString,
        paused: Bool = false,
        preset: String = "standard",
        uptimeSeconds: Int = 1,
        auditDbUserVersion: Int = 1
    ) {
        writeJSON([
            "jsonrpc": "2.0",
            "method": "sieve.hello",
            "params": [
                "protocol_version": protocolVersion,
                "daemon_version": daemonVersion,
                "daemon_boot_id": daemonBootId,
                "paused": paused,
                "preset": preset,
                "uptime_seconds": uptimeSeconds,
                "audit_db_user_version": auditDbUserVersion
            ] as [String: Any]
        ])
    }

    func sendNotification(method: String, params: [String: Any] = [:]) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if !params.isEmpty { msg["params"] = params }
        writeJSON(msg)
    }

    func sendRequest(id: String, method: String, params: [String: Any] = [:]) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { msg["params"] = params }
        writeJSON(msg)
    }

    func sendResponse(id: String, result: [String: Any]) {
        writeJSON(["jsonrpc": "2.0", "id": id, "result": result])
    }

    func sendErrorResponse(id: String, code: Int, message: String) {
        writeJSON(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    // MARK: - 接收 API

    /// 等待 GUI 发来的下一行，超时抛 MockDaemonError.timeout
    func expectNextLine(timeout: TimeInterval = 3.0) async throws -> Data {
        // 先看缓冲区
        let buffered: Data? = lock.withLock {
            receivedLines.isEmpty ? nil : receivedLines.removeFirst()
        }
        if let line = buffered { return line }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let wid = lock.withLock { () -> Int in
                waiterSeq += 1
                return waiterSeq
            }
            let work = DispatchWorkItem { [weak self] in
                self?.cancelWaiter(id: wid)
            }
            lock.withLock {
                waiters.append(Waiter(id: wid, cont: cont, workItem: work))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    func clearReceived() { lock.withLock { receivedLines.removeAll() } }
    func receivedCount() -> Int { lock.withLock { receivedLines.count } }

    // MARK: - 私有

    private func acceptLoop() {
        while serverFd >= 0 {
            var clientAddr = sockaddr_un()
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            let cfd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(serverFd, $0, &len) }
            }
            if cfd < 0 { break }
            lock.withLock {
                clientFd = cfd
                acceptedCount += 1
            }
            queue.async { [weak self] in self?.readLoop(fd: cfd) }
        }
    }

    /// 等到 acceptedCount 严格大于 `after`（用于重连场景判断 IPCClient 是否已成功 accept 新连接）
    func waitForNewConnection(after: Int = 0, timeout: TimeInterval = 5.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let cur = lock.withLock { acceptedCount }
            if cur > after { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    var connectionCount: Int { lock.withLock { acceptedCount } }

    private func readLoop(fd: Int32) {
        var lineBuf = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            lineBuf.append(contentsOf: chunk[0..<n])
            while let nl = lineBuf.firstIndex(of: 0x0A) {
                let line = lineBuf.subdata(in: lineBuf.startIndex..<nl)
                lineBuf.removeSubrange(lineBuf.startIndex...nl)
                if !line.isEmpty { deliverLine(line) }
            }
        }
    }

    private func deliverLine(_ line: Data) {
        lock.withLock {
            if !waiters.isEmpty {
                let w = waiters.removeFirst()
                w.workItem.cancel()
                w.cont.resume(returning: line)
            } else {
                receivedLines.append(line)
            }
        }
    }

    private func cancelWaiter(id: Int) {
        lock.withLock {
            if let idx = waiters.firstIndex(where: { $0.id == id }) {
                let w = waiters.remove(at: idx)
                w.cont.resume(throwing: MockDaemonError.timeout)
            }
        }
    }

    private func cancelAllWaiters() {
        lock.withLock {
            for w in waiters {
                w.workItem.cancel()
                w.cont.resume(throwing: CancellationError())
            }
            waiters.removeAll()
        }
    }

    private func writeJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return }
        var line = data
        line.append(0x0A)
        let fd = clientFd
        guard fd >= 0 else { return }
        line.withUnsafeBytes { ptr in
            _ = write(fd, ptr.baseAddress!, line.count)
        }
    }
}

enum MockDaemonError: Error {
    case timeout
    case connectionClosed
}
