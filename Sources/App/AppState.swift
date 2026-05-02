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
        ipcVersionMismatch = false
        store.setLastSeenDaemonVersion(params.daemonVersion)
        rescheduleStatus()
    }

    public func applyDisconnect(reason: DaemonStatus.DisconnectReason) {
        daemonStatus = .disconnected(reason: reason)
        if reason == .versionMismatch { ipcVersionMismatch = true }
    }

    public func setUnlockSession(_ session: UnlockSession?) {
        unlockSession = session
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
        if case .disconnected = daemonStatus { return }
        if activeRequest != nil { daemonStatus = .hold; return }
        if paused, let until = pausedUntil { daemonStatus = .paused(until: until); return }
        if warningHitCount > 0 { daemonStatus = .warning; return }
        daemonStatus = .normal
    }

    public func markConnected() {
        // 调用时机：IPCClient state 进入 .active
        if case .disconnected = daemonStatus {
            ipcVersionMismatch = false
            rescheduleStatus()
        }
    }
}
