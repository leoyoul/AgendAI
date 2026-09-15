import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@Suite("禅道会后待办适配")
struct ZentaoFollowUpTests {
    @Test("accepts ISO dates and fills an omitted todo updatedAt")
    func decodesClaudeFollowUpPayload() async throws {
        let meeting = Meeting(id: "meeting-1", title: "项目评审", createdAt: Date())
        let minutes = MeetingMinutesDocument(
            meetingID: meeting.id,
            title: meeting.title,
            meetingName: meeting.title,
            meetingDate: "2026年9月15日",
            meetingTime: "10:00-11:00",
            duration: "约60分钟",
            participants: ["张三"],
            sources: ["会议转写"],
            subtitle: "评审",
            summary: "确认交付计划。",
            conclusions: [],
            actions: [],
            risks: [],
            milestones: [],
            archiveItems: [],
            sensitiveNote: "无",
            preparedDate: "2026年9月15日"
        )
        let response = """
        {"meetingID":"meeting-1","generatedAt":"2026-09-15T02:00:00Z","todos":[{"id":"todo-1","meetingID":"meeting-1","title":"整理评审资料","projectName":"平台项目","executionName":"整理评审资料","ownerName":"张三","plannedStart":"2026-09-16","plannedEnd":"2026-09-18","source":"action","status":"matched","projectID":"p-1","executionID":"e-1","ownerID":"u-1"}]}
        """
        let client = ZentaoMCPClient(responseGenerator: { _, _, _ in response })
        let runtime = PiAgentRuntimeConfiguration(
            workingDirectoryURL: FileManager.default.temporaryDirectory,
            sessionDirectoryURL: FileManager.default.temporaryDirectory
        )
        let result = try await client.match(
            meeting: meeting,
            minutes: minutes,
            source: ModelSource(id: "agent", type: .agent, name: "Agent", baseURL: "mock://agent"),
            runtime: runtime
        )

        let todo = try #require(result.todos.first)
        #expect(result.meetingID == meeting.id)
        #expect(todo.updatedAt.timeIntervalSince1970 > 0)
        #expect(todo.projectID == "p-1")
        #expect(todo.executionID == "e-1")
        #expect(todo.ownerID == "u-1")
    }
}
