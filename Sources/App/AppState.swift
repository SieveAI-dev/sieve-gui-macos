import Foundation
import Combine
import os.log

/// 全局单一事实来源。MainActor。所有跨模块共享状态都在这里。
@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    // MARK: - daemon 与连接

    @Published public private(set) var daemonStatus: DaemonStatus = .disconnected(reason: .socketMissing)
    @Published public private(set) var daemonVersion: String? = nil
    @Published public private(set) var protocolVersion: String? = nil
    @Published public private(set) var preset: Preset = .standard
    @Published public private(set) var paused: Bool = false
    @Published public private(set) var pausedUntil: Date? = nil
    @Published public private(set) var auditDbUserVersion: Int = 0
    @Published public private(set) var auditSchemaWarning: Bool = false
    @Published public private(set) var ipcVersionMismatch: Bool = false
    @Published public private(set) var lastHandshakeAt: Date? = nil

    // MARK: - 命中与事件

    @Published public private(set) var recentHits: [HitSummary] = []
    @Published public private(set) var warningHitCount: Int = 0  // 5 分钟内 AutoRedact/StatusBar 命中数（用于角标）

    // MARK: - HIPS

    @Published public private(set) var activeRequest: HipsRequest? = nil
    @Published public private(set) var pendingQueueCount: Int = 0
    @Published public private(set) var holdRemainingSeconds: Int = 0

    // MARK: - 解锁会话

    @Published public private(set) var unlockSession: UnlockSession? = nil

    // MARK: - 设置

    @Published public var settings: UserSettings = .default

    // IPC 连接事实位：失联判定的唯一依据。不可用 daemonStatus 自身判断——那会形成
    // 自指守卫，使握手成功（markConnected/applyHello）永远无法离开失联态（2026-06-23 死锁）。
    private var ipcConnected: Bool = false
    private var lastDisconnectReason: DaemonStatus.DisconnectReason = .socketMissing

    private let store: UserSettingsStore
    private let logger = Logger(subsystem: "com.sieve.gui", category: "app-state")
    private var cancellables = Set<AnyCancellable>()
    private var pauseTimer: Timer?
    private var warningTimer: Timer?
    private var holdTimer: Timer?

    public init(store: UserSettingsStore = UserSettingsStore()) {
        self.store = store
        self.settings = store.load()
        // settings 写回 UserDefaults
        $settings
            .dropFirst()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] s in self?.store.save(s) }
            .store(in: &cancellables)
    }

    // MARK: - daemon 状态变更（由 IPCRouter 调用）

    public func updatePreset(_ p: Preset) { preset = p }

    /// 标记引导完成：同步落盘（绕过 `settings` 的 200ms debounce），避免完成/跳过后
    /// 立即退出导致时间戳未持久化、下次启动重复弹引导。
    public func markOnboardingCompleted(at date: Date = Date()) {
        settings.onboardingCompletedAt = date  // 更新内存 + 触发 @Published（UI 联动）
        store.setOnboardingCompleted(date)      // 立即同步写 UserDefaults
    }
    public func updatePaused(_ paused: Bool, until: Date?) {
        self.paused = paused
        self.pausedUntil = until
        rescheduleStatus()
        if let until = until, paused {
            pauseTimer?.invalidate()
            pauseTimer = Timer.scheduledTimer(withTimeInterval: max(0, until.timeIntervalSinceNow + 0.5), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.updatePaused(false, until: nil) }
            }
        }
    }

    public func setActiveRequest(_ req: HipsRequest?) {
        activeRequest = req
        if let req {
            holdRemainingSeconds = req.timeoutSeconds
            startHoldTimer()
        } else {
            holdRemainingSeconds = 0
            holdTimer?.invalidate()
        }
        rescheduleStatus()
    }

    public func setPendingQueueCount(_ n: Int) { pendingQueueCount = n }

    private func startHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if self.holdRemainingSeconds > 0 { self.holdRemainingSeconds -= 1 }
                if self.holdRemainingSeconds <= 0 { self.holdTimer?.invalidate() }
            }
        }
    }

    public func recordHit(_ hit: HitSummary) {
        recentHits.insert(hit, at: 0)
        if recentHits.count > 3 { recentHits.removeLast(recentHits.count - 3) }
        if hit.action == .redact || hit.action == .marked {
            bumpWarning()
        }
    }

    private func bumpWarning() {
        warningHitCount += 1
        warningTimer?.invalidate()
        warningTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.warningHitCount = 0
                self?.rescheduleStatus()
            }
        }
        rescheduleStatus()
    }

    public func setIPCVersionMismatch(_ v: Bool) {
        ipcVersionMismatch = v
        rescheduleStatus()
    }

    public func applyHello(_ params: HelloParams) {
        daemonVersion = params.daemonVersion
        protocolVersion = params.protocolVersion
        auditDbUserVersion = params.auditDbUserVersion
        preset = params.preset
        paused = params.paused
        if !params.paused { pausedUntil = nil }
        lastHandshakeAt = Date()
        ipcConnected = true
        ipcVersionMismatch = false
        store.setLastSeenDaemonVersion(params.daemonVersion)
        rescheduleStatus()
    }

    public func applyDisconnect(reason: DaemonStatus.DisconnectReason) {
        ipcConnected = false
        lastDisconnectReason = reason
        if reason == .versionMismatch { ipcVersionMismatch = true }
        rescheduleStatus()
    }

    public func setUnlockSession(_ session: UnlockSession?) {
        unlockSession = session
    }

    /// 由 History ViewModel 在打开/读取 audit.db 后回写 schema 警告位。
    /// audit.db 读取走本地 SQLite（不经 IPC），故 banner 警告不能只依赖 hello 的
    /// audit_db_user_version，需由 reader 的实际 PRAGMA user_version 判定回写。
    public func setAuditSchemaWarning(_ v: Bool) {
        auditSchemaWarning = v
    }

    public var isUnlocked: Bool {
        unlockSession?.isValid() ?? false
    }

    private func rescheduleStatus() {
        // 优先级：disconnected > hold > paused > warning > normal
        if ipcVersionMismatch {
            daemonStatus = .disconnected(reason: .versionMismatch)
            return
        }
        if !ipcConnected {
            daemonStatus = .disconnected(reason: lastDisconnectReason)
            return
        }
        if activeRequest != nil { daemonStatus = .hold; return }
        // paused 为真即进 .paused 态（until 可空）——不能因 pausedUntil 缺失就降级为 normal/warning
        // 假装健康（违反硬约束 #6）。启动握手时 daemon 已暂停但 hello 不带 paused_until 即此情形。
        if paused { daemonStatus = .paused(until: pausedUntil); return }
        if warningHitCount > 0 { daemonStatus = .warning; return }
        daemonStatus = .normal
    }

    public func markConnected() {
        // 调用时机：IPCClient state 进入 .active。置连接事实位后重算状态，使握手成功
        // 能真正离开失联态（修复自指守卫死锁）。
        ipcConnected = true
        ipcVersionMismatch = false
        rescheduleStatus()
    }
}
