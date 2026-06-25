import Testing
import Foundation
@testable import SieveGUICore

/// HIPS 倒计时阶段阈值公式测试（SPEC-002）。
///
/// 直接调用 `HipsPhase.resolve` —— 阈值公式的唯一权威实现（核心库纯函数）。
/// HipsPopupView.currentPhase 已改为转发到本函数，故公式一旦漂移这里即报警。
/// （历史教训：旧测试内联重写 `ratio > 0.5 / > 0.2`，未触达真实代码，漂移不会变红。）
@Suite("HipsPhase.resolve 阈值公式（唯一权威源）")
struct HipsPhaseResolverTests {

    // MARK: - blue（ratio > 0.5）

    @Test("ratio > 0.5 → .blue")
    func above_half_is_blue() {
        #expect(HipsPhase.resolve(remaining: 20, total: 30) == .blue) // 0.666...
        #expect(HipsPhase.resolve(remaining: 30, total: 30) == .blue) // 1.0
    }

    // MARK: - 0.5 临界（半开区间：== 0.5 归 orange）

    @Test("ratio == 0.5 → .orange（非 .blue，区间为 > 0.5 才 blue）")
    func exactly_half_is_orange() {
        #expect(HipsPhase.resolve(remaining: 15, total: 30) == .orange)
        #expect(HipsPhase.resolve(remaining: 50, total: 100) == .orange)
    }

    @Test("ratio 略高于 0.5 → .blue")
    func just_above_half_is_blue() {
        #expect(HipsPhase.resolve(remaining: 51, total: 100) == .blue)
    }

    // MARK: - orange（0.2 < ratio <= 0.5）

    @Test("0.2 < ratio < 0.5 → .orange")
    func mid_band_is_orange() {
        #expect(HipsPhase.resolve(remaining: 21, total: 100) == .orange) // 0.21
        #expect(HipsPhase.resolve(remaining: 40, total: 100) == .orange) // 0.40
    }

    // MARK: - 0.2 临界（半开区间：== 0.2 归 red）

    @Test("ratio == 0.2 → .red（非 .orange，区间为 > 0.2 才 orange）")
    func exactly_one_fifth_is_red() {
        #expect(HipsPhase.resolve(remaining: 6, total: 30) == .red)   // 0.2
        #expect(HipsPhase.resolve(remaining: 20, total: 100) == .red) // 0.2
    }

    @Test("ratio 略高于 0.2 → .orange")
    func just_above_one_fifth_is_orange() {
        #expect(HipsPhase.resolve(remaining: 21, total: 100) == .orange)
    }

    // MARK: - red（ratio <= 0.2）

    @Test("ratio < 0.2 → .red")
    func below_one_fifth_is_red() {
        #expect(HipsPhase.resolve(remaining: 5, total: 100) == .red) // 0.05
        #expect(HipsPhase.resolve(remaining: 0, total: 30) == .red)  // 0.0
    }

    // MARK: - total=0 兜底（防除零）

    @Test("total == 0 → .red（防除零兜底，最严格）")
    func zero_total_is_red() {
        #expect(HipsPhase.resolve(remaining: 30, total: 0) == .red)
        #expect(HipsPhase.resolve(remaining: 0, total: 0) == .red)
    }

    @Test("total < 0 → .red（非法输入兜底）")
    func negative_total_is_red() {
        #expect(HipsPhase.resolve(remaining: 10, total: -5) == .red)
    }
}
