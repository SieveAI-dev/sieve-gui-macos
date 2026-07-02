import Testing
import Foundation
@testable import SieveGUICore

@Suite("LiveEventsRingBuffer — 暂停只影响 UI，ring buffer 继续记录")
@MainActor
struct LiveEventsRingBufferTests {

    @Test("paused=false：append 正常写入")
    func append_when_not_paused() {
        let buf = LiveEventsRingBuffer()
        buf.paused = false
        buf.append(source: .gui, level: .info, category: "test", message: "hello")
        #expect(buf.entries.count == 1)
        #expect(buf.entries[0].message == "hello")
    }

    @Test("paused=true：append 仍然写入（ring buffer 不停止记录）")
    func append_when_paused_still_records() {
        let buf = LiveEventsRingBuffer()
        buf.paused = true
        buf.append(source: .gui, level: .info, category: "test", message: "should still record")
        // ring buffer 应继续记录，不丢弃
        #expect(buf.entries.count == 1)
        #expect(buf.entries[0].message == "should still record")
    }

    @Test("paused toggle：暂停后恢复，两段数据都在 buffer 中")
    func pause_then_resume_both_recorded() {
        let buf = LiveEventsRingBuffer()
        buf.append(source: .gui, level: .info, category: "c", message: "before-pause")
        buf.paused = true
        buf.append(source: .ipc, level: .warn, category: "c", message: "during-pause")
        buf.paused = false
        buf.append(source: .gui, level: .error, category: "c", message: "after-resume")
        #expect(buf.entries.count == 3)
    }

    @Test("paused=true：filter 使用暂停瞬间快照，append 继续写入但 UI 不刷新")
    func paused_filter_uses_snapshot_while_entries_continue_recording() {
        let buf = LiveEventsRingBuffer()
        buf.append(source: .gui, level: .info, category: "c", message: "visible-before-pause")
        buf.paused = true
        buf.append(source: .ipc, level: .warn, category: "c", message: "hidden-during-pause")

        #expect(buf.entries.count == 2)
        let visible = buf.filter(source: "all", level: "all", grep: "")
        #expect(visible.map(\.message) == ["visible-before-pause"])

        buf.paused = false
        let resumed = buf.filter(source: "all", level: "all", grep: "")
        #expect(resumed.map(\.message) == ["visible-before-pause", "hidden-during-pause"])
    }

    @Test("clear：暂停时同时清空 ring buffer 与可见快照")
    func clear_when_paused_clears_snapshot_too() {
        let buf = LiveEventsRingBuffer()
        buf.append(source: .audit, level: .info, category: "audit", message: "before")
        buf.paused = true
        buf.append(source: .audit, level: .info, category: "audit", message: "after")
        buf.clear()

        #expect(buf.entries.isEmpty)
        #expect(buf.filter(source: "all", level: "all", grep: "").isEmpty)
    }

    @Test("filter：grep 过滤 case-insensitive")
    func filter_grep_case_insensitive() {
        let buf = LiveEventsRingBuffer()
        buf.append(source: .gui, level: .info, category: "ipc", message: "HELLO World")
        buf.append(source: .gui, level: .info, category: "gui", message: "goodbye")
        let result = buf.filter(source: "all", level: "all", grep: "hello")
        #expect(result.count == 1)
        #expect(result[0].message == "HELLO World")
    }

    @Test("filter：source 过滤")
    func filter_by_source() {
        let buf = LiveEventsRingBuffer()
        buf.append(source: .gui, level: .info, category: "c", message: "gui-msg")
        buf.append(source: .ipc, level: .info, category: "c", message: "ipc-msg")
        let result = buf.filter(source: "gui", level: "all", grep: "")
        #expect(result.count == 1)
        #expect(result[0].message == "gui-msg")
    }

    @Test("source color tokens：audit=blue，ipc=orange，gui=green")
    func source_color_tokens_match_spec() {
        #expect(LiveEventsRingBuffer.sourceColorToken(.audit) == .blue)
        #expect(LiveEventsRingBuffer.sourceColorToken(.ipc) == .orange)
        #expect(LiveEventsRingBuffer.sourceColorToken(.gui) == .green)
    }
}
