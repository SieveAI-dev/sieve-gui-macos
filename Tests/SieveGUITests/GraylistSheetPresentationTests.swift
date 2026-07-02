import Testing
@testable import SieveGUICore

@Suite("Graylist sheet presentation")
struct GraylistSheetPresentationTests {
    @Test("loading 优先于错误和条目数")
    func loading_has_priority() {
        let state = GraylistSheetPresentation.resolve(
            loading: true,
            errorMessage: "加载失败，请重试",
            entryCount: 3
        )
        #expect(state == .loading)
    }

    @Test("错误状态不能被显示成空列表")
    func error_is_not_empty() {
        let state = GraylistSheetPresentation.resolve(
            loading: false,
            errorMessage: "加载失败，请重试",
            entryCount: 0
        )
        #expect(state == .error("加载失败，请重试"))
    }

    @Test("无错误且无条目时显示空状态")
    func empty_when_no_error_and_no_entries() {
        let state = GraylistSheetPresentation.resolve(
            loading: false,
            errorMessage: nil,
            entryCount: 0
        )
        #expect(state == .empty)
    }

    @Test("有条目时显示数量")
    func entries_show_count() {
        let state = GraylistSheetPresentation.resolve(
            loading: false,
            errorMessage: nil,
            entryCount: 12
        )
        #expect(state == .entries(12))
    }
}
