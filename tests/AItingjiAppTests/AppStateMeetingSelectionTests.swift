import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@MainActor
@Suite("AppState meeting selection")
struct AppStateMeetingSelectionTests {
    @Test("selecting even the current meeting refreshes meeting-scoped export data")
    func selectionRefreshesMeetingScopedData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(path: directory.appendingPathComponent("test.sqlite").path)
        let now = Date()
        let first = Meeting(
            id: "meeting-selection-first",
            title: "第一场会议",
            status: .done,
            createdAt: now
        )
        let second = Meeting(
            id: "meeting-selection-second",
            title: "第二场会议",
            status: .done,
            createdAt: now.addingTimeInterval(-60)
        )
        try store.upsertMeeting(first)
        try store.upsertMeeting(second)
        try store.upsertSegment(TranscriptSegment(
            id: "segment-selection-first",
            meetingID: first.id,
            startMs: 0,
            endMs: 1_000,
            speakerLabel: "speaker_1",
            rawText: "第一场会议内容。"
        ))
        try store.upsertSegment(TranscriptSegment(
            id: "segment-selection-second",
            meetingID: second.id,
            startMs: 0,
            endMs: 1_000,
            speakerLabel: "speaker_1",
            rawText: "第二场会议内容。"
        ))
        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        #expect(appState.selectMeeting(second.id))
        #expect(appState.selectedMeetingID == second.id)
        #expect(appState.exportPreview.contains(second.id))
        #expect(appState.exportPreview.contains("第二场会议内容。"))
        #expect(!appState.exportPreview.contains(first.id))

        appState.exportPreview = "错误的旧会议内容"
        #expect(appState.selectMeeting(second.id))
        #expect(appState.exportPreview.contains(second.id))
        #expect(!appState.exportPreview.contains("错误的旧会议内容"))
    }

    @Test("current user selection persists and clears when the person is disabled")
    func currentUserSelectionPersists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-current-user-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(path: directory.appendingPathComponent("test.sqlite").path)
        var person = VoiceprintPerson(id: "person-me", displayName: "李明")
        try store.upsertPerson(person)
        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        #expect(appState.setCurrentUserPerson(person.id))
        #expect(appState.currentUserPersonID == person.id)
        #expect(try store.loadSnapshot().appSettings[AppSettingKey.currentUserPersonID] == person.id)

        person.isActive = false
        #expect(appState.savePerson(person))
        #expect(appState.currentUserPersonID == nil)
        #expect(try store.loadSnapshot().appSettings[AppSettingKey.currentUserPersonID] == "")
    }
}
