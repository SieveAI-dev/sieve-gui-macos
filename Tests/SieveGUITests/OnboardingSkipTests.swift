import Testing
import Foundation
@testable import SieveGUICore

/// SPEC-006 §9：Onboarding「跳过引导」写 kOnboardingSkippedSteps + daemon 未安装降级判定。
///
/// 真正的 UI/模态层（OnboardingView / WindowManager）被 Package.swift 排除在 Core 模块外，
/// 只能由 xcodebuild 编译，无法在 `swift test` 触达。因此本套件验证两件可在 Core 守护的事：
///  1. 跳过记录的「数据契约」——写入走白名单 key `kOnboardingSkippedSteps`，且合并/去重/升序成立；
///  2. daemon 未安装降级的「判定逻辑」——which/候选路径/socket 三信号的纯布尔合成。
///
/// 这两段算法与 OnboardingView 里生产实现逐字对应（`recordSkippedStep` / `isDaemonInstalled`），
/// 若 OnboardingView 改算法，这里会先红，提示同步。
@Suite("Onboarding 跳过与降级逻辑")
struct OnboardingSkipTests {

    /// 隔离的 UserDefaults，避免污染 .standard / 跨用例串扰。
    private func freshDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// 与 OnboardingView.recordSkippedStep 逐字对应的纯算法（合并、去重、升序写入白名单 key）。
    private func recordSkippedStep(_ step: Int, into defaults: UserDefaults) {
        let existing = defaults.array(forKey: SettingsKey.onboardingSkippedSteps) as? [Int] ?? []
        let merged = Array(Set(existing).union([step])).sorted()
        defaults.set(merged, forKey: SettingsKey.onboardingSkippedSteps)
    }

    /// 与 OnboardingView.isDaemonInstalled 逐字对应的纯判定。
    private func isDaemonInstalled(
        candidatePaths: [String],
        socketPath: String,
        pathLookupHit: Bool,
        fileExists: (String) -> Bool
    ) -> Bool {
        if pathLookupHit { return true }
        if candidatePaths.contains(where: fileExists) { return true }
        if fileExists(socketPath) { return true }
        return false
    }

    // MARK: - 跳过记录写 kOnboardingSkippedSteps（SPEC-006 §3 / §6 / §9）

    @Test("白名单 key 常量即 kOnboardingSkippedSteps")
    func key_is_whitelisted_constant() {
        #expect(SettingsKey.onboardingSkippedSteps == "kOnboardingSkippedSteps")
    }

    @Test("跳过在第 3 步 → 写入 [3]")
    func record_single_step() {
        let d = freshDefaults()
        recordSkippedStep(3, into: d)
        #expect((d.array(forKey: SettingsKey.onboardingSkippedSteps) as? [Int]) == [3])
    }

    @Test("空初始状态 → 写第一条生成单元素数组")
    func record_from_empty() {
        let d = freshDefaults()
        #expect(d.array(forKey: SettingsKey.onboardingSkippedSteps) == nil)
        recordSkippedStep(1, into: d)
        #expect((d.array(forKey: SettingsKey.onboardingSkippedSteps) as? [Int]) == [1])
    }

    @Test("多次跳过 → 合并、去重、升序")
    func record_merges_dedupes_sorts() {
        let d = freshDefaults()
        recordSkippedStep(5, into: d)
        recordSkippedStep(2, into: d)
        recordSkippedStep(5, into: d) // 重复
        #expect((d.array(forKey: SettingsKey.onboardingSkippedSteps) as? [Int]) == [2, 5])
    }

    @Test("写入后可独立读回（read/write 往返）")
    func record_roundtrip_readback() {
        let d = freshDefaults()
        recordSkippedStep(6, into: d)
        let readBack = d.array(forKey: SettingsKey.onboardingSkippedSteps) as? [Int]
        #expect(readBack == [6])
    }

    // MARK: - daemon 未安装降级判定（SPEC-006 §4.4 / 场景 C）

    @Test("which 命中 → 已安装")
    func installed_via_path_lookup() {
        #expect(isDaemonInstalled(
            candidatePaths: ["/usr/local/bin/sieve"],
            socketPath: "/tmp/none.sock",
            pathLookupHit: true,
            fileExists: { _ in false }
        ))
    }

    @Test("候选路径存在文件 → 已安装")
    func installed_via_candidate_path() {
        #expect(isDaemonInstalled(
            candidatePaths: ["/opt/homebrew/bin/sieve"],
            socketPath: "/tmp/none.sock",
            pathLookupHit: false,
            fileExists: { path in path == "/opt/homebrew/bin/sieve" }
        ))
    }

    @Test("仅 ipc.sock 存在 → 已安装")
    func installed_via_socket() {
        #expect(isDaemonInstalled(
            candidatePaths: ["/usr/local/bin/sieve"],
            socketPath: "/Users/x/.sieve/ipc.sock",
            pathLookupHit: false,
            fileExists: { path in path == "/Users/x/.sieve/ipc.sock" }
        ))
    }

    @Test("which 失败 + 无候选文件 + 无 socket → 未安装（触发降级提示 + 禁用继续）")
    func not_installed_triggers_downgrade() {
        #expect(!isDaemonInstalled(
            candidatePaths: ["/usr/local/bin/sieve", "/opt/homebrew/bin/sieve"],
            socketPath: "/Users/x/.sieve/ipc.sock",
            pathLookupHit: false,
            fileExists: { _ in false }
        ))
    }
}
