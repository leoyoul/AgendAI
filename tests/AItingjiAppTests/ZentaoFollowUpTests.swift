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

    @Test("normalizes the known Claude fallback shape without accepting fake MCP data")
    func normalizesKnownFallbackShape() async throws {
        let meeting = makeMeeting()
        let response = """
        查询说明：MCP 权限已完成处理，以下是结果。
        ```json
        {"meetingID":"meeting-1","generatedAt":"2026-09-15T00:00:00+08:00","todos":[{"id":1,"meetingID":"meeting-1","title":"整理演示环境","projectName":null,"executionName":null,"ownerName":"待确认","plannedStart":null,"plannedEnd":null,"source":"action-[20:30-21:10]","status":"pending","projectID":null,"executionID":null,"ownerID":null,"errorMessage":null}]}
        ```
        """
        let client = ZentaoMCPClient(responseGenerator: { _, _, _ in response })
        let runtime = PiAgentRuntimeConfiguration(workingDirectoryURL: FileManager.default.temporaryDirectory, sessionDirectoryURL: FileManager.default.temporaryDirectory)
        let result = try await client.match(
            meeting: meeting,
            minutes: makeMinutes(for: meeting),
            source: ModelSource(id: "agent", type: .agent, name: "Agent", baseURL: "mock://agent"),
            runtime: runtime
        )

        let todo = try #require(result.todos.first)
        #expect(todo.id == "1")
        #expect(todo.projectName == "待确认")
        #expect(todo.executionName == "待确认")
        #expect(todo.plannedStart == "待确认")
        #expect(todo.source == .action)
        #expect(result.normalizationWarnings.count >= 5)
    }

    @Test("reports denied MCP tools instead of decoding the fallback prose")
    func reportsPermissionDenied() async throws {
        let meeting = makeMeeting()
        let response = "Claude requested permissions to use mcp__zentao__get_projects, but permission denied."
        let client = ZentaoMCPClient(responseGenerator: { _, _, _ in response })
        let runtime = PiAgentRuntimeConfiguration(workingDirectoryURL: FileManager.default.temporaryDirectory, sessionDirectoryURL: FileManager.default.temporaryDirectory)

        do {
            _ = try await client.match(
                meeting: meeting,
                minutes: makeMinutes(for: meeting),
                source: ModelSource(id: "agent", type: .agent, name: "Agent", baseURL: "mock://agent"),
                runtime: runtime
            )
            Issue.record("预期禅道 MCP 权限错误")
        } catch let error as ZentaoMCPError {
            guard case .permissionDenied(let tools) = error else {
                Issue.record("收到非预期错误：\(error.localizedDescription)")
                return
            }
            #expect(tools == ["mcp__zentao__get_projects"])
            #expect(error.diagnostic.phase == "permission")
        }
    }

    @Test("performs only one structured-output repair retry")
    func retriesContractFailureOnce() async throws {
        let meeting = makeMeeting()
        let queue = ResponseQueue(values: [
            "{\"meetingID\":\"meeting-1\",\"generatedAt\":\"2026-09-15T00:00:00Z\",\"todos\":[{\"id\":true}]}",
            "{\"meetingID\":\"meeting-1\",\"generatedAt\":\"2026-09-15T00:00:00Z\",\"todos\":[]}"
        ])
        let client = ZentaoMCPClient(responseGenerator: { _, _, _ in await queue.next() })
        let runtime = PiAgentRuntimeConfiguration(workingDirectoryURL: FileManager.default.temporaryDirectory, sessionDirectoryURL: FileManager.default.temporaryDirectory)
        let result = try await client.match(
            meeting: meeting,
            minutes: makeMinutes(for: meeting),
            source: ModelSource(id: "agent", type: .agent, name: "Agent", baseURL: "mock://agent"),
            runtime: runtime
        )
        #expect(result.todos.isEmpty)
        #expect(result.normalizationWarnings.first == "结构化输出校验失败后已执行一次修复重试。")
        #expect(await queue.count() == 0)
    }

    @Test("uses read-only allowlisted tools for matching")
    func usesLeastPrivilegeMatchOptions() async throws {
        let meeting = makeMeeting()
        let capture = InvocationCapture()
        let response = "{\"meetingID\":\"meeting-1\",\"generatedAt\":\"2026-09-15T00:00:00Z\",\"todos\":[]}"
        let client = ZentaoMCPClient(configuredResponseGenerator: { _, _, _, options in
            await capture.set(options)
            return response
        })
        let runtime = PiAgentRuntimeConfiguration(workingDirectoryURL: FileManager.default.temporaryDirectory, sessionDirectoryURL: FileManager.default.temporaryDirectory)
        _ = try await client.match(
            meeting: meeting,
            minutes: makeMinutes(for: meeting),
            source: ModelSource(id: "agent", type: .agent, name: "Agent", baseURL: "mock://agent"),
            runtime: runtime
        )

        let options = try #require(await capture.value())
        #expect(options.allowedTools == ZentaoMCPClient.readOnlyToolNames)
        #expect(!options.allowedTools.contains(ZentaoMCPClient.postTasksToolName))
        #expect(options.builtInTools == "")
        #expect(options.permissionPrompts == "none")
        #expect(options.jsonSchema?.contains("meetingID") == true)
    }

    @Test("adds post_tasks only for explicit handoff")
    func usesWriteToolOnlyForHandoff() async throws {
        let meeting = makeMeeting()
        let capture = InvocationCapture()
        let response = """
        {"id":"todo-1","meetingID":"meeting-1","title":"整理评审资料","projectName":"平台项目","executionName":"整理评审资料","ownerName":"张三","plannedStart":"2026-09-16","plannedEnd":"2026-09-18","source":"action","status":"handedOff","projectID":"p-1","executionID":"e-1","ownerID":"u-1","taskID":"task-1","errorMessage":null}
        """
        let client = ZentaoMCPClient(configuredResponseGenerator: { _, _, _, options in
            await capture.set(options)
            return response
        })
        let runtime = PiAgentRuntimeConfiguration(workingDirectoryURL: FileManager.default.temporaryDirectory, sessionDirectoryURL: FileManager.default.temporaryDirectory)
        let todo = ZentaoFollowUpTodo(
            id: "todo-1", meetingID: meeting.id, title: "整理评审资料", projectName: "平台项目",
            executionName: "整理评审资料", ownerName: "张三", plannedStart: "2026-09-16",
            plannedEnd: "2026-09-18", source: .action, status: .matched,
            projectID: "p-1", executionID: "e-1", ownerID: "u-1"
        )
        let result = try await client.create(
            todo: todo,
            meeting: meeting,
            source: ModelSource(id: "agent", type: .agent, name: "Agent", baseURL: "mock://agent"),
            runtime: runtime
        )

        let options = try #require(await capture.value())
        #expect(result.status == .handedOff)
        #expect(options.allowedTools.dropLast() == ZentaoMCPClient.readOnlyToolNames)
        #expect(options.allowedTools.last == ZentaoMCPClient.postTasksToolName)
        #expect(options.jsonSchema?.contains("handedOff") == true)
    }

    private func makeMeeting() -> Meeting {
        Meeting(id: "meeting-1", title: "项目评审", createdAt: Date())
    }

    private func makeMinutes(for meeting: Meeting) -> MeetingMinutesDocument {
        MeetingMinutesDocument(
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
    }
}

private actor ResponseQueue {
    private var values: [String]

    init(values: [String]) { self.values = values }

    func next() -> String {
        values.isEmpty ? "{}" : values.removeFirst()
    }

    func count() -> Int { values.count }
}

private actor InvocationCapture {
    private var stored: ClaudeCodeInvocationOptions?

    func set(_ value: ClaudeCodeInvocationOptions) { stored = value }
    func value() -> ClaudeCodeInvocationOptions? { stored }
}
