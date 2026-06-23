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
        let backup = defaults.dictionaryRepresentation()
        let backupKey = "_backup_\(stamp)_v\(currentVersion)"
        defaults.set(backup, forKey: backupKey)
        for (k, _) in defaults.dictionaryRepresentation() where k.hasPrefix("k") {
            defaults.removeObject(forKey: k)
        }
        defaults.set(SettingsKey.currentSchemaVersion, forKey: SettingsKey.prefsSchemaVersion)
    }
}
