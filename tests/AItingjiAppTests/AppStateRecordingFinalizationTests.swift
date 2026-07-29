import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@Suite("AppState recording finalization")
@MainActor
struct AppStateRecordingFinalizationTests {
    @Test("startup removes stale meeting-minutes recovery markers from failed meetings")
    func startupPrunesFailedMeetingRecoveryMarker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-tingji-app-stale-minutes-marker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: TestModelSourceAPIKeyStore()
        )
        let meetingID = "failed-meeting-with-stale-marker"
        try store.upsertMeeting(Meeting(
            id: meetingID,
            title: "失败会议",
            status: .failed,
            createdAt: Date(),
            endedAt: Date()
        ))
        try store.setAppSetting(
            AppSettingKey.pendingPostprocessMeetingIDs,
            value: "[\"\(meetingID)\"]"
        )

        _ = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        #expect(try store.loadSnapshot().appSettings[AppSettingKey.pendingPostprocessMeetingIDs] == "[]")
    }

    @Test("completion without a meeting minutes model finishes without confirmation")
    func completionWithoutMinutesModelFinishesDirectly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-tingji-app-no-postprocess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: TestModelSourceAPIKeyStore()
        )
        let meetingID = "meeting-no-postprocess"
        try store.upsertMeeting(Meeting(
            id: meetingID,
            title: "无会议纪要模型",
            status: .processing,
            createdAt: Date(),
            endedAt: Date()
        ))
        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        appState.finalizeStoppedMeeting(meetingID: meetingID)
        await appState.waitForPostprocessing(meetingID: meetingID)

        let completed = try #require(appState.meetings.first(where: { $0.id == meetingID }))
        #expect(completed.status == .done)
        #expect(completed.handoffStatus == .ignored)
    }

    @Test("mock ASR completion finishes without confirmation")
    func mockASRCompletionFinishesDirectly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-tingji-app-mock-asr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: TestModelSourceAPIKeyStore()
        )
        let meetingID = "meeting-mock-asr"
        try store.upsertMeeting(Meeting(
            id: meetingID,
            title: "模拟转写",
            status: .draft,
            createdAt: Date()
        ))
        try store.upsertModelSource(ModelSource(
            id: "asr-mock",
            type: .asr,
            name: "Mock ASR",
            baseURL: "mock://asr",
            selectedModel: "mock",
            isDefault: true,
            enabled: true
        ))
        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        appState.transcribeMockAudioWithDefaultASR()
        for _ in 0..<100 where appState.meetings.first(where: { $0.id == meetingID })?.status != .done {
            try await Task.sleep(for: .milliseconds(10))
        }

        let completed = try #require(appState.meetings.first(where: { $0.id == meetingID }))
        #expect(completed.status == .done)
        #expect(completed.handoffStatus == .ignored)
    }

    @Test("mock ASR success updates the meeting that started it after selection changes")
    func mockASRSuccessKeepsOriginalMeetingIdentity() async throws {
        let fixture = try ASRSelectionFixture(name: "success", baseURL: "mock://asr")
        defer { fixture.remove() }
        let appState = fixture.makeAppState()
        appState.selectedMeetingID = fixture.firstMeetingID

        appState.transcribeMockAudioWithDefaultASR()
        appState.selectedMeetingID = fixture.secondMeetingID

        for _ in 0..<200 where appState.meetings.first(where: { $0.id == fixture.firstMeetingID })?.status != .done {
            try await Task.sleep(for: .milliseconds(20))
        }

        let first = try #require(appState.meetings.first(where: { $0.id == fixture.firstMeetingID }))
        let second = try #require(appState.meetings.first(where: { $0.id == fixture.secondMeetingID }))
        #expect(first.status == .done)
        #expect(first.handoffStatus == .ignored)
        #expect(appState.segmentsByMeeting[fixture.firstMeetingID]?.count == 1)
        #expect(second.status == .draft)
        #expect(second.handoffStatus == .ignored)
        #expect(appState.segmentsByMeeting[fixture.secondMeetingID, default: []].isEmpty)
        #expect(appState.selectedMeetingID == fixture.secondMeetingID)
    }

    @Test("mock ASR failure updates the meeting that started it after selection changes")
    func mockASRFailureKeepsOriginalMeetingIdentity() async throws {
        let fixture = try ASRSelectionFixture(name: "failure", baseURL: "http://127.0.0.1:1/v1")
        defer { fixture.remove() }
        let appState = fixture.makeAppState()
        appState.selectedMeetingID = fixture.firstMeetingID

        appState.transcribeMockAudioWithDefaultASR()
        appState.selectedMeetingID = fixture.secondMeetingID

        for _ in 0..<200 where appState.meetings.first(where: { $0.id == fixture.firstMeetingID })?.status != .failed {
            try await Task.sleep(for: .milliseconds(20))
        }

        let first = try #require(appState.meetings.first(where: { $0.id == fixture.firstMeetingID }))
        let second = try #require(appState.meetings.first(where: { $0.id == fixture.secondMeetingID }))
        #expect(first.status == .failed)
        #expect(second.status == .draft)
        #expect(second.handoffStatus == .ignored)
        #expect(appState.segmentsByMeeting[fixture.secondMeetingID, default: []].isEmpty)
        #expect(appState.selectedMeetingID == fixture.secondMeetingID)
    }

    @Test("automatic minutes keep realtime transcript unchanged and preserve legacy speaker data")
    func automaticMinutesUseRealtimeTranscriptWithoutRewritingIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-tingji-app-finalization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: TestModelSourceAPIKeyStore()
        )
        let meetingID = "meeting-realtime-only"
        let segmentID = "segment-live"
        try store.upsertMeeting(Meeting(
            id: meetingID,
            title: "新会议 1",
            status: .processing,
            captureSource: .microphone,
            createdAt: Date(timeIntervalSince1970: 1_784_100_000),
            startedAt: Date(timeIntervalSince1970: 1_784_100_010),
            endedAt: Date(timeIntervalSince1970: 1_784_100_610)
        ))
        try store.upsertSegment(TranscriptSegment(
            id: segmentID,
            meetingID: meetingID,
            startMs: 0,
            endMs: 10_000,
            speakerLabel: "未分配发言人",
            autoSpeakerLabel: "未分配发言人",
            rawText: "我们讨论产品路线和交付风险",
            processedText: "我们讨论产品路线和交付风险",
            finalText: "我们讨论产品路线和交付风险"
        ))
        try store.upsertDiarizationRun(DiarizationRun(
            id: "legacy-run",
            meetingID: meetingID,
            scope: .full,
            status: .failed,
            audioFilePath: "/legacy/recording.wav"
        ))
        try store.upsertModelSource(ModelSource(
            id: "minutes-mock",
            type: .agent,
            name: "Mock meeting minutes",
            baseURL: "mock://meeting-minutes",
            selectedModel: "mock",
            isDefault: true,
            enabled: true
        ))
        try store.upsertModelSource(ModelSource(
            id: "legacy-voiceprint",
            type: .voiceprint,
            name: "Legacy voiceprint",
            baseURL: "sidecar://diarization",
            selectedModel: "legacy",
            isDefault: true,
            enabled: true
        ))
        try store.setAppSetting(
            AppSettingKey.pendingPostprocessMeetingIDs,
            value: "[\"\(meetingID)\"]"
        )

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false,
            meetingMinutesGenerator: MeetingMinutesGenerator(
                storageDirectory: directory.appendingPathComponent("MeetingMinutes")
            )
        )

        appState.finalizeStoppedMeeting(meetingID: meetingID)
        await appState.waitForPostprocessing(meetingID: meetingID)

        #expect(appState.segmentsByMeeting[meetingID]?.map(\.id) == [segmentID])
        #expect(appState.segmentsByMeeting[meetingID]?.first?.finalText == "我们讨论产品路线和交付风险")
        #expect(appState.meetings.first(where: { $0.id == meetingID })?.status == .done)
        #expect(appState.meetings.first(where: { $0.id == meetingID })?.handoffStatus == .ignored)
        #expect(appState.meetings.first(where: { $0.id == meetingID })?.title == "项目进展与后续安排")
        #expect(appState.meetingMinutesArtifacts[meetingID]?.markdown.contains("## 五、后续行动项") == true)
        #expect(appState.diarizationRunsByMeeting[meetingID]?.map(\.id) == ["legacy-run"])
        #expect(appState.modelSources.contains(where: { $0.id == "legacy-voiceprint" }))
        #expect(!appState.modelSources.contains(where: { $0.id == VoiceprintModelMigration.bundledSidecarID }))
        #expect(appState.recentlyCompletedMeetingIDs.contains(meetingID))
        #expect(!appState.isMeetingPostprocessing(meetingID))

        appState.acknowledgeMeetingCompletion(meetingID)
        #expect(!appState.recentlyCompletedMeetingIDs.contains(meetingID))
    }

    @Test("interrupted automatic minutes generation resumes after app restart")
    func interruptedMinutesGenerationResumes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-tingji-app-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: TestModelSourceAPIKeyStore()
        )
        let meetingID = "meeting-interrupted-postprocess"
        try store.upsertMeeting(Meeting(
            id: meetingID,
            title: "新会议 1",
            status: .processing,
            captureSource: .microphone,
            createdAt: Date(timeIntervalSince1970: 1_784_100_000),
            startedAt: Date(timeIntervalSince1970: 1_784_100_010),
            endedAt: Date(timeIntervalSince1970: 1_784_100_610)
        ))
        try store.upsertSegment(TranscriptSegment(
            id: "segment-live",
            meetingID: meetingID,
            startMs: 0,
            endMs: 10_000,
            speakerLabel: "未分配发言人",
            rawText: "嗯我们讨论恢复后处理"
        ))
        try store.upsertModelSource(ModelSource(
            id: "minutes-mock",
            type: .agent,
            name: "Mock meeting minutes",
            baseURL: "mock://meeting-minutes",
            selectedModel: "mock",
            isDefault: true,
            enabled: true
        ))
        try store.setAppSetting(
            AppSettingKey.pendingPostprocessMeetingIDs,
            value: "[\"\(meetingID)\"]"
        )

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: true,
            meetingMinutesGenerator: MeetingMinutesGenerator(
                storageDirectory: directory.appendingPathComponent("MeetingMinutes")
            )
        )

        for _ in 0..<100 {
            if appState.meetings.first(where: { $0.id == meetingID })?.status == .done {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(appState.meetings.first(where: { $0.id == meetingID })?.status == .done)
        #expect(appState.meetings.first(where: { $0.id == meetingID })?.handoffStatus == .ignored)
        #expect(appState.recentlyCompletedMeetingIDs.contains(meetingID))
        #expect(!appState.isMeetingPostprocessing(meetingID))
        #expect(appState.meetingMinutesArtifacts[meetingID] != nil)
    }

    @Test("processing status without a postprocess marker is not auto-polished")
    func interruptedRetranscriptionIsNotTreatedAsPostprocess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-tingji-app-retranscription-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: TestModelSourceAPIKeyStore()
        )
        let meetingID = "meeting-interrupted-retranscription"
        let originalText = "嗯这是尚未完成的重转写片段"
        try store.upsertMeeting(Meeting(
            id: meetingID,
            title: "旧会议",
            status: .processing,
            captureSource: .microphone,
            createdAt: Date(timeIntervalSince1970: 1_784_100_000),
            startedAt: Date(timeIntervalSince1970: 1_784_100_010),
            endedAt: Date(timeIntervalSince1970: 1_784_100_610)
        ))
        try store.upsertSegment(TranscriptSegment(
            id: "partial-segment",
            meetingID: meetingID,
            startMs: 0,
            endMs: 10_000,
            speakerLabel: "未分配发言人",
            rawText: originalText
        ))
        try store.upsertModelSource(ModelSource(
            id: "postprocess-mock",
            type: .postprocess,
            name: "Mock postprocess",
            baseURL: "mock://postprocess",
            selectedModel: "mock",
            isDefault: true,
            enabled: true
        ))

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: true
        )
        for _ in 0..<100 where appState.meetings.first(where: { $0.id == meetingID })?.status == .processing {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(appState.meetings.first(where: { $0.id == meetingID })?.status == .failed)
        #expect(appState.segmentsByMeeting[meetingID]?.first?.rawText == originalText)
        #expect(appState.segmentsByMeeting[meetingID]?.first?.finalText.isEmpty == true)
        #expect(!appState.recentlyCompletedMeetingIDs.contains(meetingID))
    }

    @Test("historical pending ASR stays blocked after app restart")
    func historicalPendingASRIsNotResumedOnRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-tingji-app-pending-asr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: TestModelSourceAPIKeyStore()
        )
        let meetingID = "meeting-exhausted-pending-asr"
        try store.upsertMeeting(Meeting(
            id: meetingID,
            title: "历史待转写会议",
            status: .failed,
            captureSource: .microphone,
            createdAt: Date(timeIntervalSince1970: 1_784_100_000),
            startedAt: Date(timeIntervalSince1970: 1_784_100_010),
            endedAt: Date(timeIntervalSince1970: 1_784_100_610)
        ))
        try store.upsertModelSource(ModelSource(
            id: "asr-mock",
            type: .asr,
            name: "Mock ASR",
            baseURL: "mock://asr",
            selectedModel: "mock",
            isDefault: true,
            enabled: true
        ))

        let pendingRoot = directory.appendingPathComponent("PendingASR")
        let queue = try PendingTranscriptionQueue(rootDirectoryURL: pendingRoot)
        let record = try await queue.enqueue(
            meetingID: meetingID,
            chunk: AudioChunk(
                sequence: 1,
                startMs: 0,
                endMs: 100,
                samples: Array(repeating: 0.1, count: 1_600),
                format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
            )
        )
        for _ in 0..<PendingTranscriptionQueue.defaultMaximumAttempts {
            _ = try #require(try await queue.next(meetingID: meetingID))
            _ = try await queue.markFailed(id: record.id)
        }
        _ = try await queue.enqueue(
            meetingID: meetingID,
            chunk: AudioChunk(
                sequence: 2,
                startMs: 100,
                endMs: 200,
                samples: Array(repeating: 0.1, count: 1_600),
                format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
            )
        )

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: pendingRoot,
            resumePendingTranscriptions: true
        )
        try await Task.sleep(for: .milliseconds(200))

        let recoveredQueue = try PendingTranscriptionQueue(rootDirectoryURL: pendingRoot)
        let recoveredRecords = await recoveredQueue.pendingRecords(meetingID: meetingID)
        #expect(recoveredRecords.map(\.attemptCount) == [PendingTranscriptionQueue.defaultMaximumAttempts, 0])
        #expect(appState.segmentsByMeeting[meetingID, default: []].isEmpty)
        #expect(appState.meetings.first(where: { $0.id == meetingID })?.status == .failed)
    }

    @Test("ASR timeout and cancellation are not retried automatically")
    func asrTimeoutIsNotRetriedAutomatically() {
        #expect(!AppState.shouldAutomaticallyRetryASR(after: URLError(.timedOut)))
        #expect(!AppState.shouldAutomaticallyRetryASR(after: URLError(.cancelled)))
        #expect(AppState.shouldAutomaticallyRetryASR(after: URLError(.cannotConnectToHost)))
    }
}

private final class ASRSelectionFixture {
    let firstMeetingID = "meeting-asr-a"
    let secondMeetingID = "meeting-asr-b"
    let directory: URL
    let store: AppPersistenceStore

    init(name: String, baseURL: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-tingji-asr-selection-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: TestModelSourceAPIKeyStore()
        )
        try store.upsertMeeting(Meeting(
            id: secondMeetingID,
            title: "会议 B",
            status: .draft,
            createdAt: Date(timeIntervalSince1970: 100)
        ))
        try store.upsertMeeting(Meeting(
            id: firstMeetingID,
            title: "会议 A",
            status: .draft,
            createdAt: Date(timeIntervalSince1970: 200)
        ))
        try store.upsertModelSource(ModelSource(
            id: "asr-selection-\(name)",
            type: .asr,
            name: "ASR selection \(name)",
            baseURL: baseURL,
            selectedModel: "mock",
            isDefault: true,
            enabled: true
        ))
    }

    @MainActor
    func makeAppState() -> AppState {
        AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )
    }

    func remove() {
        store.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

private final class TestModelSourceAPIKeyStore: @unchecked Sendable, ModelSourceAPIKeyStore {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func apiKey(for reference: String) throws -> String? {
        lock.withLock { values[reference] }
    }

    func setAPIKey(_ apiKey: String, for reference: String) throws {
        lock.withLock { values[reference] = apiKey }
    }

    func removeAPIKey(for reference: String) throws {
        lock.withLock { _ = values.removeValue(forKey: reference) }
    }
}
