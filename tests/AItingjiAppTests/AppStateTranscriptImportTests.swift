import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@MainActor
@Suite("AppState transcript import")
struct AppStateTranscriptImportTests {
    @Test("imported transcript enters minutes and AI analysis workflow")
    func importEntersDownstreamWorkflow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-transcript-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: TranscriptImportTestAPIKeyStore()
        )
        try store.upsertModelSource(ModelSource(
            id: "transcript-import-agent",
            type: .agent,
            name: "Agent 模型",
            baseURL: "mock://meeting-minutes",
            selectedModel: "mock",
            isDefault: true,
            enabled: true
        ))
        let minutesGenerator = MeetingMinutesGenerator(
            storageDirectory: directory.appendingPathComponent("minutes", isDirectory: true)
        )
        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false,
            meetingMinutesGenerator: minutesGenerator
        )
        let meetingDate = Date(timeIntervalSince1970: 1_700_000_000)
        let importedAt = meetingDate.addingTimeInterval(3_600)

        let meetingID = try #require(appState.importTranscript(
            title: "手机会议转写",
            content: """
            [00:00-00:04] 张三：确认交付时间。
            [00:04-00:08] 李四：周五提交验收材料。
            """,
            fileExtension: "txt",
            meetingDate: meetingDate,
            importedAt: importedAt
        ))
        await appState.waitForPostprocessing(meetingID: meetingID)

        let meeting = try #require(appState.meetings.first(where: { $0.id == meetingID }))
        #expect(meeting.captureSource == .imported)
        #expect(meeting.status == .done)
        #expect(meeting.startedAt == meetingDate)
        #expect(appState.selectedMeetingID == meetingID)
        #expect(appState.selectedSegments.count == 1)
        #expect(appState.exportPreview.contains("张三"))
        #expect(appState.selectedMeetingMinutesArtifact?.document.meetingID == meetingID)
        #expect(appState.canGenerateSelectedMeetingAnalysis)

        let snapshot = try store.loadSnapshot()
        #expect(snapshot.meetings.contains(where: { $0.id == meetingID && $0.captureSource == .imported }))
        #expect(snapshot.segmentsByMeeting[meetingID]?.count == 1)
    }

    @Test("failed import does not leave a partial meeting")
    func failedImportLeavesNoMeeting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-transcript-import-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: TranscriptImportTestAPIKeyStore()
        )
        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        #expect(appState.importTranscript(title: "空文件", content: " \n ") == nil)
        #expect(appState.meetings.isEmpty)
        #expect(try store.loadSnapshot().meetings.isEmpty)
        #expect(appState.statusMessage.contains("导入失败"))
    }

    @Test("minutes generation failure keeps the transcript and becomes retryable")
    func minutesFailureKeepsTranscriptAndBecomesRetryable() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-transcript-minutes-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: TranscriptImportTestAPIKeyStore()
        )
        try store.upsertModelSource(ModelSource(
            id: "transcript-import-failing-agent",
            type: .agent,
            name: "失败 Agent",
            baseURL: "https://agent.invalid/v1",
            selectedModel: "invalid-output",
            isDefault: true,
            enabled: true
        ))
        let probe = TranscriptImportMinutesFailureProbe()
        let minutesGenerator = MeetingMinutesGenerator(
            storageDirectory: directory.appendingPathComponent("minutes", isDirectory: true),
            modelResponseGenerator: { _, _, _ in await probe.respond() }
        )
        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false,
            meetingMinutesGenerator: minutesGenerator
        )

        let meetingID = try #require(appState.importTranscript(
            title: "失败仍保留转写",
            content: "张三：保留这条原始转写。",
            fileExtension: "txt"
        ))
        await appState.waitForPostprocessing(meetingID: meetingID)

        let meeting = try #require(appState.meetings.first(where: { $0.id == meetingID }))
        #expect(meeting.status == .failed)
        #expect(meeting.minutesGenerationError?.contains("连续 3 次") == true)
        #expect(appState.segmentsByMeeting[meetingID]?.first?.finalText == "张三：保留这条原始转写。")
        #expect(appState.meetingMinutesArtifacts[meetingID] == nil)
        #expect(!appState.recentlyCompletedMeetingIDs.contains(meetingID))
        #expect(!appState.canGenerateSelectedMeetingAnalysis)
        #expect(appState.canGenerateSelectedMeetingMinutes)
        #expect(try store.loadSnapshot().appSettings[AppSettingKey.pendingPostprocessMeetingIDs] == "[]")
        #expect(appState.statusMessage.contains("标准会议纪要生成失败"))
        #expect(appState.debugLogEntries.contains {
            $0.category == "纪要"
                && $0.message.contains("失败原因=")
                && $0.message.contains("错误类型=")
                && $0.message.contains("标准纪要生成失败")
        })
        #expect(await probe.callCount() == 6)
    }
}

private final class TranscriptImportTestAPIKeyStore: @unchecked Sendable, ModelSourceAPIKeyStore {
    func apiKey(for reference: String) throws -> String? { nil }
    func setAPIKey(_ apiKey: String, for reference: String) throws {}
    func removeAPIKey(for reference: String) throws {}
}

private actor TranscriptImportMinutesFailureProbe {
    private var calls = 0

    func respond() -> String {
        calls += 1
        return "不是结构化会议纪要"
    }

    func callCount() -> Int { calls }
}
