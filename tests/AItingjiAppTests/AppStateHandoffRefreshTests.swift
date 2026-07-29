import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@Suite("AppState handoff refresh")
@MainActor
struct AppStateHandoffRefreshTests {
    @Test("external handoff refresh merges confirmed title and handoff owned fields")
    func externalHandoffRefreshMergesConfirmedTitleAndPreservesRecordingState() throws {
        let fixture = try HandoffAppFixture(name: "refresh")
        defer { fixture.remove() }
        let meetingID = "meeting-refresh"
        let inMemoryMeeting = Meeting(
            id: meetingID,
            title: "内存标题",
            status: .recording,
            captureSource: .mixed,
            createdAt: Date(timeIntervalSince1970: 100),
            startedAt: Date(timeIntervalSince1970: 110),
            endedAt: Date(timeIntervalSince1970: 120),
            audioFilePath: "/app/audio.wav"
        )
        try fixture.store.upsertMeeting(inMemoryMeeting)
        let appState = fixture.makeAppState()

        let externalDatabase = try Database(path: fixture.databasePath)
        try externalDatabase.migrate()
        try externalDatabase.execute(
            """
            UPDATE meetings
            SET title = '外部确认的新标题', status = 'done', capture_source = 'microphone',
                is_archived = 1, handoff_status = 'completed',
                handoff_started_at = 200, handoff_completed_at = 300,
                handoff_content_hash = 'hash-v1'
            WHERE id = ?
            """,
            bindings: [.text(meetingID)]
        )

        appState.refreshHandoffStateFromPersistence()
        let refreshed = try #require(appState.meetings.first(where: { $0.id == meetingID }))
        #expect(refreshed.title == "外部确认的新标题")
        #expect(refreshed.status == .recording)
        #expect(refreshed.captureSource == .mixed)
        #expect(refreshed.audioFilePath == "/app/audio.wav")
        #expect(refreshed.isArchived)
        #expect(refreshed.handoffStatus == .completed)
        #expect(refreshed.handoffCompletedAt == Date(timeIntervalSince1970: 300))
        #expect(!appState.visibleMeetings.contains(where: { $0.id == meetingID }))
        #expect(appState.archivedMeetings.contains(where: { $0.id == meetingID }))
        externalDatabase.close()
    }

    @Test("archived meeting restores without confirmation state")
    func completedMeetingCanBeRestored() throws {
        let fixture = try HandoffAppFixture(name: "restore")
        defer { fixture.remove() }
        let meetingID = "meeting-restore"
        var meeting = Meeting(
            id: meetingID,
            title: "待恢复会议",
            status: .done,
            createdAt: Date()
        )
        meeting.isArchived = true
        meeting.handoffStatus = .completed
        meeting.handoffCompletedAt = Date(timeIntervalSince1970: 300)
        meeting.handoffContentHash = "hash-v1"
        try fixture.store.upsertMeeting(meeting)
        let appState = fixture.makeAppState()

        #expect(appState.restoreMeeting(meetingID))
        let restored = try #require(appState.meetings.first(where: { $0.id == meetingID }))
        #expect(!restored.isArchived)
        #expect(restored.handoffStatus == .ignored)
        #expect(restored.handoffCompletedAt == nil)
        #expect(restored.handoffContentHash == nil)
    }

    @Test("legacy review-ready meeting stays visible and editable")
    func legacyReviewReadyMeetingStaysVisibleAndEditable() throws {
        let fixture = try HandoffAppFixture(name: "review-ready")
        defer { fixture.remove() }
        let meetingID = "meeting-review-ready"
        var meeting = Meeting(
            id: meetingID,
            title: "旧交接会议",
            status: .done,
            createdAt: Date()
        )
        meeting.handoffStatus = .completed
        meeting.handoffCompletedAt = Date(timeIntervalSince1970: 300)
        meeting.handoffContentHash = "hash-review"
        try fixture.store.upsertMeeting(meeting)
        let appState = fixture.makeAppState()

        #expect(appState.visibleMeetings.contains(where: { $0.id == meetingID }))
        #expect(!appState.isMeetingContentLocked(meetingID))
    }

    @Test("Darwin handoff notification refreshes external archive")
    func DarwinNotificationRefreshesState() async throws {
        let fixture = try HandoffAppFixture(name: "notify")
        defer { fixture.remove() }
        let meetingID = "meeting-notify"
        try fixture.store.upsertMeeting(Meeting(
            id: meetingID,
            title: "通知刷新",
            status: .done,
            createdAt: Date()
        ))
        let appState = fixture.makeAppState()
        appState.startObservingHandoffChanges()

        let externalDatabase = try Database(path: fixture.databasePath)
        try externalDatabase.migrate()
        try externalDatabase.execute(
            """
            UPDATE meetings
            SET title = '通知后的新标题', is_archived = 1,
                handoff_status = 'completed', handoff_completed_at = 400
            WHERE id = ?
            """,
            bindings: [.text(meetingID)]
        )
        let notify = Process()
        notify.executableURL = URL(fileURLWithPath: "/usr/bin/notifyutil")
        notify.arguments = ["-p", HandoffChangeObserver.notificationName]
        try notify.run()
        notify.waitUntilExit()
        #expect(notify.terminationStatus == 0)

        for _ in 0..<100 where appState.meetings.first(where: { $0.id == meetingID })?.isArchived != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(appState.meetings.first(where: { $0.id == meetingID })?.isArchived == true)
        #expect(appState.meetings.first(where: { $0.id == meetingID })?.handoffStatus == .completed)
        #expect(appState.meetings.first(where: { $0.id == meetingID })?.title == "通知后的新标题")
        externalDatabase.close()
    }
}

private final class HandoffAppFixture {
    let directory: URL
    let databasePath: String
    let store: AppPersistenceStore

    init(name: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AItingji-app-handoff-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databasePath = directory.appendingPathComponent("test.sqlite").path
        store = try AppPersistenceStore(
            path: databasePath,
            apiKeyStore: HandoffTestModelSourceAPIKeyStore()
        )
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

private final class HandoffTestModelSourceAPIKeyStore: @unchecked Sendable, ModelSourceAPIKeyStore {
    func apiKey(for reference: String) throws -> String? { nil }
    func setAPIKey(_ apiKey: String, for reference: String) throws {}
    func removeAPIKey(for reference: String) throws {}
}
