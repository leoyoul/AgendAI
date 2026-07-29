import AItingjiCore
import Foundation
import Testing

@Suite("Meeting Agent turn timeline")
struct MeetingAgentTurnTimelineTests {
    @Test("keeps commentary, later processing, and final answer as ordered segments")
    func orderedLongRunningTurn() {
        var message = MeetingAgentChatMessage(
            meetingID: "meeting-1",
            role: .assistant,
            content: "",
            status: .streaming
        )

        message.appendAgentActivity("已载入会议上下文")
        message.appendAgentReasoning("先检查资料。")
        message.appendAgentText("我先核对现有文件。")
        message.appendAgentActivity("开始调用：read")
        message.appendAgentActivity("调用完成：read")
        message.appendAgentReasoning("资料已齐，开始汇总。")
        message.appendAgentText("## 结论\n\n已完成核对。")
        message.completeAgentTurn(finalText: "## 结论\n\n已完成核对。")

        #expect(message.timeline.map(\.kind) == [.process, .commentary, .process, .final])
        #expect(message.timeline[0].reasoning == "先检查资料。")
        #expect(message.timeline[1].content == "我先核对现有文件。")
        #expect(message.timeline[2].activity == ["开始调用：read", "调用完成：read"])
        #expect(message.timeline[2].reasoning == "资料已齐，开始汇总。")
        #expect(message.timeline[3].content == "## 结论\n\n已完成核对。")
        #expect(message.content == "## 结论\n\n已完成核对。")
        #expect(message.status == .completed)
    }

    @Test("decodes legacy messages without a timeline")
    func legacyDecoding() throws {
        let data = Data("""
        {
          "id":"message-1",
          "meetingID":"meeting-1",
          "role":"assistant",
          "content":"旧回复",
          "reasoning":"旧思考",
          "activity":["旧记录"],
          "status":"completed",
          "createdAt":0,
          "updatedAt":0
        }
        """.utf8)

        let message = try JSONDecoder().decode(MeetingAgentChatMessage.self, from: data)
        #expect(message.timeline.isEmpty)
        #expect(message.content == "旧回复")
    }
}
