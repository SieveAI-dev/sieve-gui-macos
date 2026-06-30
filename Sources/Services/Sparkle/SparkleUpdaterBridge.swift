import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

/// 包装 Sparkle 的 SPUStandardUpdaterController，仅在 General/检查更新时使用。
/// 红线：决策路径不联网。Sparkle 是唯一的网络出口，与 HIPS 分离。
@MainActor
public final class SparkleUpdaterBridge: NSObject {
    public static let shared = SparkleUpdaterBridge()

    #if canImport(Sparkle)
    private let updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    public var isAutoCheckEnabled: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    public func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
    #else
    public var isAutoCheckEnabled: Bool = false
    public func checkForUpdates() {
        Task { await GUILog.shared.warn("Sparkle 不可用：跳过检查更新") }
    }
    #endif
}

extension SparkleUpdaterBridge: AppUpdater {}
