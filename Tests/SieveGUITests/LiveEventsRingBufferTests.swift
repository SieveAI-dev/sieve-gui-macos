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
}
