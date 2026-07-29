import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@MainActor
@Suite("App debug log")
struct AppDebugLogTests {
    @Test("test process keeps the default debug log outside user data")
    func testProcessUsesTemporaryDefaultLog() {
        #expect(!AppDebugLogStore.defaultFileURL().path.contains("/Library/Application Support/会小纪/"))
    }

    @Test("debug events persist in chronological order and keep the newest entries")
    func debugEventsPersistAndTrim() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-debug-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logStore = AppDebugLogStore(
            fileURL: directory.appendingPathComponent("events.jsonl"),
            maximumEntries: 2
        )
        try logStore.append(AppDebugLogEntry(
            id: "first",
            timestamp: Date(timeIntervalSince1970: 1),
            category: "状态",
            message: "第一条"
        ))
        try logStore.append(AppDebugLogEntry(
            id: "second",
            timestamp: Date(timeIntervalSince1970: 2),
            category: "纪要",
            message: "第二条"
        ))
        try logStore.append(AppDebugLogEntry(
            id: "third",
            timestamp: Date(timeIntervalSince1970: 3),
            category: "归档",
            message: "第三条"
        ))

        #expect(logStore.load().map(\.id) == ["third", "second"])
    }

    @Test("manual minutes generation cannot coexist with an external archive update")
    func externalArchiveCancelsManualMinutesGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-debug-archive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: DebugLogTestAPIKeyStore()
        )
        let meeting = Meeting(
            id: "debug-archive-meeting",
            title: "并发归档测试",
            status: .done,
            createdAt: Date()
        )
        try store.upsertMeeting(meeting)
        try store.upsertSegment(TranscriptSegment(
            id: "debug-archive-segment",
            meetingID: meeting.id,
            startMs: 0,
            endMs: 5_000,
            speakerLabel: "张三",
            rawText: "请生成会议纪要。"
        ))
        try store.upsertModelSource(ModelSource(
            id: "debug-agent",
            type: .agent,
            name: "调试 Agent",
            baseURL: "https://agent.invalid/v1",
            selectedModel: "debug",
            isDefault: true,
            enabled: true
        ))

        let started = DebugMinutesStartSignal()
        let generator = MeetingMinutesGenerator(
            storageDirectory: directory.appendingPathComponent("minutes", isDirectory: true),
            modelResponseGenerator: { _, _, _ in
                await started.markStarted()
                try await Task.sleep(for: .seconds(30))
                return "{}"
            }
        )
        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false,
            meetingMinutesGenerator: generator,
            debugLogStore: AppDebugLogStore(fileURL: directory.appendingPathComponent("events.jsonl"))
        )
        #expect(appState.selectMeeting(meeting.id))
        appState.generateSelectedMeetingMinutes()
        for _ in 0..<100 where !(await started.hasStarted()) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(appState.isMeetingMinutesActive(meeting.id))
        #expect(!appState.archiveMeeting(meeting.id))

        try store.setMeetingArchived(id: meeting.id, isArchived: true)
        appState.refreshHandoffStateFromPersistence()
        for _ in 0..<100 where appState.isMeetingMinutesActive(meeting.id) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!appState.isMeetingMinutesActive(meeting.id))
        #expect(appState.meetings.first(where: { $0.id == meeting.id })?.isArchived == true)
        #expect(appState.debugLogEntries.contains { $0.message.contains("取消正在运行") })
    }
}

private final class DebugLogTestAPIKeyStore: @unchecked Sendable, ModelSourceAPIKeyStore {
    func apiKey(for reference: String) throws -> String? { nil }
    func setAPIKey(_ apiKey: String, for reference: String) throws {}
    func removeAPIKey(for reference: String) throws {}
}

private actor DebugMinutesStartSignal {
    private var started = false

    func markStarted() {
        started = true
    }

    func hasStarted() -> Bool { started }
}
