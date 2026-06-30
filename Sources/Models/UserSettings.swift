import Foundation

/// UserDefaults 白名单。任何不在此列表的字段都不允许写入。
public enum SettingsKey {
    public static let prefsSchemaVersion = "prefsSchemaVersion"
    public static let onboardingCompletedAt = "kOnboardingCompletedAt"
    public static let onboardingSkippedSteps = "kOnboardingSkippedSteps"
    public static let appearance = "kAppearance"
    public static let language = "kLanguage"
    public static let hipsSoundEnabled = "kHipsSoundEnabled"
    public static let hipsSoundName = "kHipsSoundName"
    public static let reduceMotionOverride = "kReduceMotionOverride"
    public static let toastDurationSeconds = "kToastDurationSeconds"
    public static let historyMaskByDefault = "kHistoryMaskByDefault"
    public static let autoCheckUpdates = "kAutoCheckUpdates"
    public static let loginItemEnabled = "kLoginItemEnabled"
    public static let lastSeenDaemonVersion = "kLastSeenDaemonVersion"
    public static let lastIPCErrorTimestamp = "kLastIPCErrorTimestamp"
    public static let panelLastFramePrefix = "kPanelLastFrame_"
    public static let lastSeenDaemonBootId = "kLastSeenDaemonBootId"

    public static let currentSchemaVersion: Int = 1

    /// 本 App 管理的全部固定键（不含 `panelLastFramePrefix` 这类动态前缀键）。
    /// schema 迁移时用它精确备份/清除，避免用模糊的 "k" 前缀匹配误伤系统全局键。
    public static let allManagedKeys: [String] = [
        prefsSchemaVersion, onboardingCompletedAt, onboardingSkippedSteps,
        appearance, language, hipsSoundEnabled, hipsSoundName, reduceMotionOverride,
        toastDurationSeconds, historyMaskByDefault, autoCheckUpdates, loginItemEnabled,
        lastSeenDaemonVersion, lastIPCErrorTimestamp, lastSeenDaemonBootId
    ]
}

public struct UserSettings: Sendable, Equatable {
    public var appearance: String           // "system" | "light" | "dark"
    public var language: String             // "system" | "zh-Hans" | "en"
    public var hipsSoundEnabled: Bool
    public var hipsSoundName: String
    public var reduceMotionOverride: String // "system" | "always" | "never"
    public var toastDurationSeconds: Int    // 3...10
    public var historyMaskByDefault: Bool
    public var autoCheckUpdates: Bool
    public var loginItemEnabled: Bool
    public var onboardingCompletedAt: Date?

    public static let `default` = UserSettings(
        appearance: "system",
        language: "system",
        hipsSoundEnabled: true,
        hipsSoundName: "Funk",
        reduceMotionOverride: "system",
        toastDurationSeconds: 5,
        historyMaskByDefault: true,
        autoCheckUpdates: true,
        loginItemEnabled: true,
        onboardingCompletedAt: nil
    )

    /// 解析最终的 reduce-motion 生效值（纯函数，无 AppKit 依赖，可单测）。
    /// - `reduceMotionOverride == "always"` → 恒 true（用户强制减少动画）
    /// - `reduceMotionOverride == "never"`  → 恒 false（用户强制保留动画）
    /// - 其他（含 "system"）→ 透传系统 flag
    /// - Parameter systemReduceMotion: 系统 `accessibilityDisplayShouldReduceMotion` 的当前值
    public func reduceMotionEnabled(systemReduceMotion: Bool) -> Bool {
        switch reduceMotionOverride {
        case "always": return true
        case "never": return false
        default: return systemReduceMotion
        }
    }
}

public enum GraylistSheetPresentation: Sendable, Equatable {
    case loading
    case error(String)
    case empty
    case entries(Int)

    public static func resolve(loading: Bool, errorMessage: String?, entryCount: Int) -> GraylistSheetPresentation {
        if loading { return .loading }
        if let errorMessage, !errorMessage.isEmpty { return .error(errorMessage) }
        if entryCount == 0 { return .empty }
        return .entries(entryCount)
    }
}

@MainActor
public protocol AppUpdater: AnyObject {
    var isAutoCheckEnabled: Bool { get set }
    func checkForUpdates()
}

@MainActor
public enum UpdateSettingsSync {
    public static func applyAutoCheckSetting(_ enabled: Bool, to updater: AppUpdater) {
        updater.isAutoCheckEnabled = enabled
    }
}

public final class UserSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bootstrapSchema()
    }

    public func load() -> UserSettings {
        let s = UserSettings.default
        return UserSettings(
            appearance: defaults.string(forKey: SettingsKey.appearance) ?? s.appearance,
            language: defaults.string(forKey: SettingsKey.language) ?? s.language,
            hipsSoundEnabled: defaults.object(forKey: SettingsKey.hipsSoundEnabled) as? Bool ?? s.hipsSoundEnabled,
            hipsSoundName: defaults.string(forKey: SettingsKey.hipsSoundName) ?? s.hipsSoundName,
            reduceMotionOverride: defaults.string(forKey: SettingsKey.reduceMotionOverride) ?? s.reduceMotionOverride,
            toastDurationSeconds: clampToast(defaults.object(forKey: SettingsKey.toastDurationSeconds) as? Int ?? s.toastDurationSeconds),
            historyMaskByDefault: defaults.object(forKey: SettingsKey.historyMaskByDefault) as? Bool ?? s.historyMaskByDefault,
            autoCheckUpdates: defaults.object(forKey: SettingsKey.autoCheckUpdates) as? Bool ?? s.autoCheckUpdates,
            loginItemEnabled: defaults.object(forKey: SettingsKey.loginItemEnabled) as? Bool ?? s.loginItemEnabled,
            onboardingCompletedAt: defaults.object(forKey: SettingsKey.onboardingCompletedAt) as? Date
        )
    }

    public func save(_ settings: UserSettings) {
        defaults.set(settings.appearance, forKey: SettingsKey.appearance)
        defaults.set(settings.language, forKey: SettingsKey.language)
        defaults.set(settings.hipsSoundEnabled, forKey: SettingsKey.hipsSoundEnabled)
        defaults.set(settings.hipsSoundName, forKey: SettingsKey.hipsSoundName)
        defaults.set(settings.reduceMotionOverride, forKey: SettingsKey.reduceMotionOverride)
        defaults.set(clampToast(settings.toastDurationSeconds), forKey: SettingsKey.toastDurationSeconds)
        defaults.set(settings.historyMaskByDefault, forKey: SettingsKey.historyMaskByDefault)
        defaults.set(settings.autoCheckUpdates, forKey: SettingsKey.autoCheckUpdates)
        defaults.set(settings.loginItemEnabled, forKey: SettingsKey.loginItemEnabled)
        defaults.set(settings.onboardingCompletedAt, forKey: SettingsKey.onboardingCompletedAt)
    }

    public func setOnboardingCompleted(_ date: Date?) {
        defaults.set(date, forKey: SettingsKey.onboardingCompletedAt)
    }

    public func setLastSeenDaemonVersion(_ version: String) {
        defaults.set(version, forKey: SettingsKey.lastSeenDaemonVersion)
    }

    public func lastSeenDaemonBootId() -> String? {
        defaults.string(forKey: SettingsKey.lastSeenDaemonBootId)
    }

    public func setLastSeenDaemonBootId(_ bootId: String) {
        defaults.set(bootId, forKey: SettingsKey.lastSeenDaemonBootId)
    }

    private func clampToast(_ v: Int) -> Int { max(3, min(10, v)) }

    private func bootstrapSchema() {
        let stored = defaults.integer(forKey: SettingsKey.prefsSchemaVersion)
        if stored == 0 {
            defaults.set(SettingsKey.currentSchemaVersion, forKey: SettingsKey.prefsSchemaVersion)
        } else if stored != SettingsKey.currentSchemaVersion {
            // 不兼容 → 备份并重置（参考 data-model.md）
            backupAndReset(currentVersion: stored)
        }
    }

    private func backupAndReset(currentVersion: Int) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let backupKey = "_backup_\(stamp)_v\(currentVersion)"
        let all = defaults.dictionaryRepresentation()

        // 只备份本 App 管理的键（固定白名单 + 动态的 panel frame 前缀键），不 dump 整个
        // UserDefaults 域——后者会把系统/全局键也写进备份，造成脏数据、体积膨胀甚至
        // 写入非 plist 类型时崩溃。
        var backup: [String: Any] = [:]
        for key in SettingsKey.allManagedKeys {
            if let v = defaults.object(forKey: key) { backup[key] = v }
        }
        for (k, v) in all where k.hasPrefix(SettingsKey.panelLastFramePrefix) {
            backup[k] = v
        }
        defaults.set(backup, forKey: backupKey)

        // 精确清除本 App 管理的键，避免用 "k" 前缀模糊匹配误删系统/其他子系统的同前缀键。
        for key in SettingsKey.allManagedKeys {
            defaults.removeObject(forKey: key)
        }
        for k in all.keys where k.hasPrefix(SettingsKey.panelLastFramePrefix) {
            defaults.removeObject(forKey: k)
        }
        defaults.set(SettingsKey.currentSchemaVersion, forKey: SettingsKey.prefsSchemaVersion)
    }
}
