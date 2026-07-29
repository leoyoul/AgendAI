import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@Suite("Meeting Agent context")
struct MeetingAgentContextBuilderTests {
    @Test("prompt includes minutes, active people, terminology notes, transcript, and history")
    func completeLocalContext() {
        let meeting = Meeting(
            id: "meeting-context",
            title: "项目复盘",
            status: .done,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let segment = TranscriptSegment(
            id: "segment-1",
            meetingID: meeting.id,
            startMs: 65_000,
            endMs: 66_000,
            speakerLabel: "说话人 1",
            personName: "李明",
            finalText: "确认下一步计划"
        )
        let people = [
            VoiceprintPerson(
                id: "person-active",
                displayName: "李明",
                aliases: ["Leo"],
                jobTitle: "产品负责人",
                roleTags: ["决策"]
            ),
            VoiceprintPerson(id: "person-disabled", displayName: "停用人员", isActive: false)
        ]
        let terminology = [
            TerminologyEntry(
                id: "term-active",
                canonicalName: "会小纪",
                aliases: ["AgendAI"],
                category: "产品",
                notes: "会议录音与纪要应用"
            ),
            TerminologyEntry(id: "term-disabled", canonicalName: "停用词", isActive: false)
        ]
        let history = [
            MeetingAgentChatMessage(
                id: "history-1",
                meetingID: meeting.id,
                role: .user,
                content: "谁确认了计划？",
                createdAt: Date(timeIntervalSince1970: 2)
            )
        ]

        let prompt = MeetingAgentContextBuilder.buildPrompt(
            meeting: meeting,
            segments: [segment],
            minutesMarkdown: "# 会议纪要\n结论已确认",
            people: people,
            currentUserPersonID: "person-active",
            terminology: terminology,
            history: history,
            knowledgeContext: "产品文档依据",
            question: "我的名字是什么？"
        )

        #expect(prompt.contains("[01:05] 李明：确认下一步计划"))
        #expect(prompt.contains("# 会议纪要"))
        #expect(prompt.contains("李明；称呼：Leo；岗位：产品负责人；角色：决策"))
        #expect(prompt.contains("李明（人员库中的本人）"))
        #expect(prompt.contains("身份：当前用户本人"))
        #expect(prompt.contains("会小纪；别称：AgendAI；类别：产品；说明：会议录音与纪要应用"))
        #expect(prompt.contains("用户：谁确认了计划？"))
        #expect(prompt.contains("产品文档依据"))
        #expect(!prompt.contains("停用人员"))
        #expect(!prompt.contains("停用词"))
    }

    @Test("long transcript and history are compacted within the prompt budget")
    func compactsLongContext() {
        let meeting = Meeting(
            id: "meeting-long-context",
            title: "长会议",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let segment = TranscriptSegment(
            id: "segment-long",
            meetingID: meeting.id,
            startMs: 0,
            endMs: 1_000,
            speakerLabel: "说话人 1",
            finalText: String(repeating: "长期会议内容", count: 8_000)
        )
        let history = (0..<20).map { index in
            MeetingAgentChatMessage(
                id: "history-\(index)",
                meetingID: meeting.id,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "第\(index)轮" + String(repeating: "历史内容", count: 800)
            )
        }

        let context = MeetingAgentContextBuilder.buildContext(
            meeting: meeting,
            segments: [segment],
            minutesMarkdown: String(repeating: "会议纪要", count: 4_000),
            people: [],
            currentUserPersonID: nil,
            terminology: [],
            history: history,
            knowledgeContext: String(repeating: "知识库", count: 4_000),
            question: "总结"
        )

        #expect(context.usage.wasCompacted)
        #expect(context.usage.includedHistoryMessages == 6)
        #expect(context.usage.omittedHistoryMessages == 14)
        #expect(context.usage.estimatedTokens <= context.usage.tokenBudget)
        #expect(context.prompt.contains("较早聊天压缩摘要"))
        #expect(context.prompt.contains("…（上下文过长，中间内容已省略）…"))
    }

    @Test("continued Pi sessions receive only the current turn delta")
    func continuedSessionUsesIncrementalContext() {
        let meeting = Meeting(
            id: "meeting-continuation",
            title: "项目复盘",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let person = VoiceprintPerson(id: "person-current", displayName: "李明", isActive: true)
        let context = MeetingAgentContextBuilder.buildContinuationContext(
            meeting: meeting,
            people: [person],
            currentUserPersonID: person.id,
            knowledgeContext: "本轮知识命中",
            question: "继续给出下一步"
        )

        #expect(context.prompt.contains("继续 AgendAI 会小纪中同一场会议的 Pi Agent 会话"))
        #expect(context.prompt.contains("项目复盘"))
        #expect(context.prompt.contains("李明（人员库中的本人）"))
        #expect(context.prompt.contains("本轮知识命中"))
        #expect(context.prompt.contains("继续给出下一步"))
        #expect(!context.prompt.contains("【会议转写】"))
        #expect(!context.prompt.contains("【近期聊天】"))
        #expect(context.usage.includedHistoryMessages == 0)
    }
}
