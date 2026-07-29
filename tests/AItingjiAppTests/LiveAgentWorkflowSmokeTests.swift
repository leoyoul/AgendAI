import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@Suite("Live Agent workflow smoke", .serialized)
struct LiveAgentWorkflowSmokeTests {
    @Test("synthetic structured minutes and Pi analysis run through the configured Agent model")
    func syntheticEndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["TINGLAN_LIVE_AGENT_WORKFLOW"] == "1" else { return }
        let store = try AppPersistenceStore()
        defer { store.close() }
        let source = try #require(
            try store.loadSnapshot().modelSources.first {
                $0.type == .agent && $0.enabled && $0.isDefault
            }
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-live-agent-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let meeting = Meeting(
            id: "synthetic-live-smoke",
            title: "合成会议 Agent 验收",
            status: .done,
            createdAt: Date(),
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(600)
        )
        let segments = [TranscriptSegment(
            id: "synthetic-segment-1",
            meetingID: meeting.id,
            startMs: 0,
            endMs: 10_000,
            speakerLabel: "测试主持人",
            rawText: "这是一段纯合成测试资料。请在下周五前整理 Swift 6 官方并发模型的资料，形成一页验收清单，由测试负责人负责。"
        )]
        let original = try await MeetingMinutesGenerator(
            storageDirectory: root.appendingPathComponent("minutes", isDirectory: true)
        ).generate(
            meeting: meeting,
            segments: segments,
            source: source,
            vocabulary: .empty
        )
        #expect(original.document.meetingID == meeting.id)
        #expect(original.markdown.contains("合成"))

        let resources = PiAgentResourceResolver().resolve()
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let analysis = try await MeetingAnalysisGenerator(
            storageDirectory: root.appendingPathComponent("analysis", isDirectory: true)
        ).generate(
            meeting: meeting,
            segments: segments,
            originalMinutes: original,
            people: [VoiceprintPerson(
                id: "synthetic-owner",
                displayName: "测试负责人",
                jobTitle: "验收工程师",
                roleTags: ["测试"],
                responsibilities: "负责技术资料核验和交付验收"
            )],
            terminology: [TerminologyEntry(
                id: "synthetic-term",
                canonicalName: "验收清单",
                notes: "用于记录核验项、依据和结论"
            )],
            knowledgeContext: "",
            source: source,
            runtime: PiAgentRuntimeConfiguration(
                workingDirectoryURL: workspace,
                sessionDirectoryURL: root.appendingPathComponent("session", isDirectory: true),
                extensionURLs: resources.extensions,
                skillURLs: resources.skills,
                sessionName: "合成会议 Agent 验收"
            )
        )
        #expect(!analysis.document.findings.isEmpty)
        #expect(!analysis.document.todos.isEmpty)
        #expect(analysis.document.todos.allSatisfy { $0.owner == "测试负责人" || $0.owner == "待确认" })
    }
}
