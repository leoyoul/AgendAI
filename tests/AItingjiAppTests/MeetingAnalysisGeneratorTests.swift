import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@Suite("AI analysis meeting minutes")
@MainActor
struct MeetingAnalysisGeneratorTests {
    @Test("analysis prompt includes responsibilities, terminology, knowledge, and original minutes")
    func analysisContextAndStructuredTodo() async throws {
        let directory = try temporaryDirectory("analysis-context")
        defer { try? FileManager.default.removeItem(at: directory) }
        let meeting = sampleMeeting(id: "analysis-context")
        let originalMinutes = try await makeOriginalMinutes(meeting: meeting, directory: directory)
        let captured = PromptCapture()
        let generator = MeetingAnalysisGenerator(
            storageDirectory: directory.appendingPathComponent("analysis", isDirectory: true),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            agentResponseGenerator: { _, prompt, _ in
                await captured.set(prompt)
                return #"{"title":"项目交付 AI 分析会议纪要","executive_summary":"会议事实与外部分析已分层。","findings":[{"topic":"交付安排","analysis":"需要明确验收闭环。","basis":"会议转写与知识库"}],"todos":[{"id":"todo-1","item":"整理交付计划","owner":"张敏","task":"梳理实施步骤和依赖","deliverable":"交付计划表","deadline":"2026-08-01（建议，待确认）","assignment_basis":"职责匹配建议，待确认","evidence":"会议转写 00:00"}],"risks":["期限需确认"],"sources":["项目知识库"]}"#
            }
        )
        let person = VoiceprintPerson(
            id: "person-tang",
            displayName: "张敏",
            jobTitle: "项目经理",
            roleTags: ["交付"],
            responsibilities: "负责项目计划、实施协调和交付验收"
        )
        let runtime = PiAgentRuntimeConfiguration(
            workingDirectoryURL: directory,
            sessionDirectoryURL: directory.appendingPathComponent("session", isDirectory: true)
        )
        let artifact = try await generator.generate(
            meeting: meeting,
            segments: sampleSegments(meetingID: meeting.id),
            originalMinutes: originalMinutes,
            people: [person],
            terminology: [TerminologyEntry(
                id: "term-1",
                canonicalName: "交付验收",
                notes: "项目交付完成标准"
            )],
            knowledgeContext: "[项目知识库] 交付前需要完成验收。",
            source: agentSource(baseURL: "https://agent.example.test/v1"),
            runtime: runtime,
            prompt: "自定义 AI 分析要求：优先评估交付风险和验收依赖。"
        )

        let prompt = try #require(await captured.value())
        #expect(prompt.contains("自定义 AI 分析要求：优先评估交付风险和验收依赖。"))
        #expect(prompt.contains("负责项目计划、实施协调和交付验收"))
        #expect(prompt.contains("交付验收"))
        #expect(prompt.contains("项目知识库"))
        #expect(prompt.contains(originalMinutes.document.summary))
        #expect(artifact.document.todos.first?.owner == "张敏")
        #expect(artifact.document.todos.first?.deliverable == "交付计划表")
        #expect(artifact.markdown.contains("| 整理交付计划 | 张敏 |"))
        #expect(artifact.html.contains("AI 分析会议纪要"))
    }

    @Test("task dispatch prefers ZenTao-mapped people and keeps the required chapter")
    func taskDispatchPriorityAndTemplate() async throws {
        let directory = try temporaryDirectory("analysis-dispatch-priority")
        defer { try? FileManager.default.removeItem(at: directory) }
        let captured = PromptCapture()
        let accountPerson = VoiceprintPerson(
            id: "person-account",
            displayName: "黄茂辉",
            jobTitle: "研发负责人",
            responsibilities: "负责技术方案和研发交付",
            zentaoAccount: "huangmh"
        )
        let localPerson = VoiceprintPerson(
            id: "person-local",
            displayName: "张敏",
            jobTitle: "项目经理",
            responsibilities: "负责项目计划和实施协调"
        )
        let generator = MeetingAnalysisGenerator(
            storageDirectory: directory.appendingPathComponent("analysis", isDirectory: true),
            agentResponseGenerator: { _, prompt, _ in
                await captured.set(prompt)
                return #"{"title":"任务分工分析","executive_summary":"已形成执行安排。","findings":[],"todos":[{"id":"todo-1","item":"完成技术方案","owner":"黄茂辉","task":"整理技术方案并提交评审","deliverable":"技术方案评审稿","deadline":"待确认","assignment_basis":"职责匹配建议，待确认","evidence":"会议转写 00:00"}],"risks":[],"sources":["会议转写"]}"#
            }
        )
        let artifact = try await generator.generate(
            meeting: sampleMeeting(id: "analysis-dispatch-priority"),
            segments: sampleSegments(meetingID: "analysis-dispatch-priority"),
            originalMinutes: nil,
            people: [localPerson, accountPerson],
            terminology: [],
            knowledgeContext: "",
            source: agentSource(baseURL: "https://agent.example.test/v1"),
            runtime: PiAgentRuntimeConfiguration(
                workingDirectoryURL: directory,
                sessionDirectoryURL: directory.appendingPathComponent("session", isDirectory: true)
            )
        )

        let prompt = try #require(await captured.value())
        #expect(prompt.contains("第一优先级：有禅道账号；姓名：黄茂辉"))
        #expect(prompt.contains("第二优先级：无禅道账号；姓名：张敏"))
        let accountLine = try #require(prompt.range(of: "第一优先级：有禅道账号；姓名：黄茂辉"))
        let localLine = try #require(prompt.range(of: "第二优先级：无禅道账号；姓名：张敏"))
        #expect(accountLine.lowerBound < localLine.lowerBound)
        #expect(artifact.document.todos.first?.owner == "黄茂辉")
        #expect(artifact.markdown.contains("## 任务分工派发"))
        #expect(artifact.markdown.contains("| 完成技术方案 | 黄茂辉 |"))
        #expect(artifact.html.contains("class=\"topbar\""))
        #expect(artifact.html.contains("class=\"rail\""))
        #expect(artifact.html.contains("class=\"hero\""))
        #expect(artifact.html.contains("<h2>任务分工派发</h2>"))
        #expect(artifact.html.contains("progress-value"))
    }

    @Test("empty task output still renders the required dispatch chapter")
    func emptyTaskDispatchChapter() {
        let document = MeetingAnalysisDocument(
            meetingID: "empty-dispatch",
            title: "空任务分析",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            executiveSummary: "暂无任务。",
            findings: [],
            todos: [],
            risks: [],
            sources: []
        )

        let markdown = MeetingAnalysisRenderer.markdown(document)
        let html = MeetingAnalysisRenderer.html(document)
        #expect(markdown.contains("## 任务分工派发"))
        #expect(markdown.contains("暂无可确认任务"))
        #expect(html.contains("<h2>任务分工派发</h2>"))
        #expect(html.contains("暂无可确认任务"))
    }

    @Test("mock analysis also prefers a ZenTao-mapped person")
    func mockTaskDispatchPriority() async throws {
        let directory = try temporaryDirectory("analysis-mock-dispatch")
        defer { try? FileManager.default.removeItem(at: directory) }
        let generator = MeetingAnalysisGenerator(
            storageDirectory: directory.appendingPathComponent("analysis", isDirectory: true)
        )
        let artifact = try await generator.generate(
            meeting: sampleMeeting(id: "analysis-mock-dispatch"),
            segments: sampleSegments(meetingID: "analysis-mock-dispatch"),
            originalMinutes: nil,
            people: [
                VoiceprintPerson(id: "person-local", displayName: "张敏"),
                VoiceprintPerson(id: "person-account", displayName: "黄茂辉", zentaoAccount: "huangmh")
            ],
            terminology: [],
            knowledgeContext: "",
            source: agentSource(baseURL: "mock://agent"),
            runtime: PiAgentRuntimeConfiguration(
                workingDirectoryURL: directory,
                sessionDirectoryURL: directory.appendingPathComponent("session", isDirectory: true)
            )
        )

        #expect(artifact.document.todos.first?.owner == "黄茂辉")
    }

    @Test("loading an existing analysis refreshes the cached template")
    func refreshesCachedTemplateOnLoad() async throws {
        let directory = try temporaryDirectory("analysis-template-migration")
        defer { try? FileManager.default.removeItem(at: directory) }
        let generator = MeetingAnalysisGenerator(
            storageDirectory: directory.appendingPathComponent("analysis", isDirectory: true)
        )
        let meeting = sampleMeeting(id: "analysis-template-migration")
        _ = try await generator.generate(
            meeting: meeting,
            segments: sampleSegments(meetingID: meeting.id),
            originalMinutes: nil,
            people: [],
            terminology: [],
            knowledgeContext: "",
            source: agentSource(baseURL: "mock://agent"),
            runtime: PiAgentRuntimeConfiguration(
                workingDirectoryURL: directory,
                sessionDirectoryURL: directory.appendingPathComponent("session", isDirectory: true)
            )
        )
        let htmlURL = try #require(generator.cachedHTMLURL(meetingID: meeting.id))
        try "<h2>待办清单</h2>".write(to: htmlURL, atomically: true, encoding: .utf8)

        let loaded = try #require(try generator.load(meetingID: meeting.id))
        let refreshedHTML = try String(contentsOf: htmlURL, encoding: .utf8)
        #expect(loaded.html.contains("<h2>任务分工派发</h2>"))
        #expect(refreshedHTML.contains("<h2>任务分工派发</h2>"))
        #expect(!refreshedHTML.contains("<h2>待办清单</h2>"))
    }

    @Test("AI analysis prompt can be saved, restored, and reloaded")
    func persistsMeetingAnalysisPrompt() throws {
        let directory = try temporaryDirectory("analysis-prompt")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: AnalysisTestAPIKeyStore()
        )
        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        #expect(appState.meetingAnalysisPrompt == PostprocessPrompt.meetingAnalysis)
        appState.updateMeetingAnalysisPrompt("仅输出执行风险和待办优先级。")
        #expect(try store.loadSnapshot().appSettings[AppSettingKey.meetingAnalysisPrompt] == "仅输出执行风险和待办优先级。")

        let reloaded = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR-reloaded"),
            resumePendingTranscriptions: false
        )
        #expect(reloaded.meetingAnalysisPrompt == "仅输出执行风险和待办优先级。")
        reloaded.updateMeetingAnalysisPrompt("   ")
        #expect(reloaded.meetingAnalysisPrompt == PostprocessPrompt.meetingAnalysis)
        #expect(try store.loadSnapshot().appSettings[AppSettingKey.meetingAnalysisPrompt] == PostprocessPrompt.meetingAnalysis)
    }

    @Test("AI analysis is manual, persists independently, and restores after restart")
    func manualGenerationAndRestore() async throws {
        let directory = try temporaryDirectory("analysis-app-state")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: AnalysisTestAPIKeyStore()
        )
        let meeting = sampleMeeting(id: "analysis-app-state")
        try store.upsertMeeting(meeting)
        for segment in sampleSegments(meetingID: meeting.id) {
            try store.upsertSegment(segment)
        }
        try store.upsertPerson(VoiceprintPerson(
            id: "person-huang",
            displayName: "黄茂辉",
            responsibilities: "负责技术方案和研发交付"
        ))
        try store.upsertModelSource(agentSource(baseURL: "mock://agent"))

        let minutesGenerator = MeetingMinutesGenerator(
            storageDirectory: directory.appendingPathComponent("minutes", isDirectory: true)
        )
        _ = try await minutesGenerator.generate(
            meeting: meeting,
            segments: sampleSegments(meetingID: meeting.id),
            source: agentSource(baseURL: "mock://agent")
        )
        let analysisGenerator = MeetingAnalysisGenerator(
            storageDirectory: directory.appendingPathComponent("analysis", isDirectory: true)
        )
        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false,
            meetingMinutesGenerator: minutesGenerator,
            meetingAnalysisGenerator: analysisGenerator
        )
        #expect(appState.selectMeeting(meeting.id))
        #expect(appState.selectedMeetingAnalysisArtifact == nil)
        #expect(appState.canGenerateSelectedMeetingAnalysis)

        appState.generateSelectedMeetingAnalysis()
        for _ in 0..<200 where appState.generatingMeetingAnalysisIDs.contains(meeting.id) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(appState.selectedMeetingAnalysisArtifact?.document.todos.first?.owner == "黄茂辉")
        #expect(appState.statusMessage.contains("任务分工已按人员职责整理"))

        let reloaded = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR-reloaded"),
            resumePendingTranscriptions: false,
            meetingMinutesGenerator: minutesGenerator,
            meetingAnalysisGenerator: analysisGenerator
        )
        #expect(reloaded.selectMeeting(meeting.id))
        #expect(reloaded.selectedMeetingAnalysisArtifact?.document.todos.first?.owner == "黄茂辉")
    }

    @Test("running analysis protects the meeting and can be cancelled")
    func cancellationAndDeletionProtection() async throws {
        let directory = try temporaryDirectory("analysis-cancellation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: AnalysisTestAPIKeyStore()
        )
        let meeting = sampleMeeting(id: "analysis-cancellation")
        try store.upsertMeeting(meeting)
        for segment in sampleSegments(meetingID: meeting.id) {
            try store.upsertSegment(segment)
        }
        try store.upsertModelSource(agentSource(baseURL: "https://agent.example.test/v1"))
        let minutesGenerator = MeetingMinutesGenerator(
            storageDirectory: directory.appendingPathComponent("minutes", isDirectory: true)
        )
        _ = try await minutesGenerator.generate(
            meeting: meeting,
            segments: sampleSegments(meetingID: meeting.id),
            source: agentSource(baseURL: "mock://agent")
        )
        let started = AnalysisStartSignal()
        let analysisGenerator = MeetingAnalysisGenerator(
            storageDirectory: directory.appendingPathComponent("analysis", isDirectory: true),
            agentResponseGenerator: { _, _, _ in
                await started.markStarted()
                try await Task.sleep(for: .seconds(30))
                return "{}"
            }
        )
        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false,
            meetingMinutesGenerator: minutesGenerator,
            meetingAnalysisGenerator: analysisGenerator
        )
        #expect(appState.selectMeeting(meeting.id))
        appState.generateSelectedMeetingAnalysis()
        for _ in 0..<100 where !(await started.hasStarted()) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(appState.isMeetingProtectedFromMutation(meeting.id))
        #expect(!appState.deleteMeeting(meeting.id))
        appState.stopSelectedMeetingAnalysis()
        for _ in 0..<100 where appState.generatingMeetingAnalysisIDs.contains(meeting.id) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!appState.generatingMeetingAnalysisIDs.contains(meeting.id))
        #expect(!appState.isMeetingProtectedFromMutation(meeting.id))
    }

    private func makeOriginalMinutes(meeting: Meeting, directory: URL) async throws -> MeetingMinutesArtifact {
        try await MeetingMinutesGenerator(
            storageDirectory: directory.appendingPathComponent("minutes", isDirectory: true)
        ).generate(
            meeting: meeting,
            segments: sampleSegments(meetingID: meeting.id),
            source: agentSource(baseURL: "mock://agent")
        )
    }

    private func sampleMeeting(id: String) -> Meeting {
        Meeting(
            id: id,
            title: "项目交付讨论",
            status: .done,
            createdAt: Date(timeIntervalSince1970: 1_784_100_000),
            startedAt: Date(timeIntervalSince1970: 1_784_100_010),
            endedAt: Date(timeIntervalSince1970: 1_784_100_610)
        )
    }

    private func sampleSegments(meetingID: String) -> [TranscriptSegment] {
        [TranscriptSegment(
            id: "segment-1",
            meetingID: meetingID,
            startMs: 0,
            endMs: 10_000,
            speakerLabel: "张敏",
            rawText: "请整理项目交付计划并明确验收时间。"
        )]
    }

    private func agentSource(baseURL: String) -> ModelSource {
        ModelSource(
            id: "agent-analysis",
            type: .agent,
            name: "Agent",
            baseURL: baseURL,
            apiKey: "test-key",
            selectedModel: "agent-model",
            isDefault: true,
            enabled: true
        )
    }

    private func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor PromptCapture {
    private var prompt: String?

    func set(_ value: String) {
        prompt = value
    }

    func value() -> String? {
        prompt
    }
}

private actor AnalysisStartSignal {
    private var started = false

    func markStarted() {
        started = true
    }

    func hasStarted() -> Bool {
        started
    }
}

private final class AnalysisTestAPIKeyStore: @unchecked Sendable, ModelSourceAPIKeyStore {
    func apiKey(for reference: String) throws -> String? { nil }
    func setAPIKey(_ apiKey: String, for reference: String) throws {}
    func removeAPIKey(for reference: String) throws {}
}
