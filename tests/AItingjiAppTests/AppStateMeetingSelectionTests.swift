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

    @Test("calendar visibility persists independently from active state")
    func calendarVisibilityFiltersPeopleAndSurvivesReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-calendar-visibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("test.sqlite").path
        let store = try AppPersistenceStore(path: path)
        try store.upsertPerson(VoiceprintPerson(id: "person-hidden", displayName: "隐藏人员"))
        try store.upsertPerson(VoiceprintPerson(
            id: "person-visible",
            displayName: "显示人员",
            isCalendarVisible: true
        ))
        try store.upsertPerson(VoiceprintPerson(
            id: "person-inactive",
            displayName: "停用人员",
            isActive: false,
            isCalendarVisible: true
        ))

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        #expect(appState.workbenchCalendarPeople.map(\.id) == ["person-visible"])

        var hidden = try #require(appState.people.first(where: { $0.id == "person-hidden" }))
        hidden.isCalendarVisible = true
        #expect(appState.savePerson(hidden))
        // 人员按创建日期正序，先创建的 person-hidden 排在前面。
        #expect(appState.workbenchCalendarPeople.map(\.id) == ["person-hidden", "person-visible"])

        hidden.isCalendarVisible = false
        #expect(appState.savePerson(hidden))
        #expect(appState.workbenchCalendarPeople.map(\.id) == ["person-visible"])

        store.close()
        let reopened = try AppPersistenceStore(path: path)
        let snapshot = try reopened.loadSnapshot()
        #expect(snapshot.people.first(where: { $0.id == "person-hidden" })?.isCalendarVisible == false)
        #expect(snapshot.people.first(where: { $0.id == "person-visible" })?.isCalendarVisible == true)
        #expect(snapshot.people.first(where: { $0.id == "person-inactive" })?.isCalendarVisible == true)
        reopened.close()
    }

    @Test("legacy unscheduled work items are recovered into the task pool")
    func unscheduledWorkItemsBecomePendingConfirmation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-work-item-pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(path: directory.appendingPathComponent("test.sqlite").path)
        try store.upsertPerson(VoiceprintPerson(id: "person-owner", displayName: "负责人"))
        try store.createWorkItem(WorkItem(
            id: "legacy-unscheduled",
            title: "补充截止日期",
            ownerPersonIDs: ["person-owner"],
            status: .notStarted
        ))

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        #expect(appState.pendingConfirmationWorkItems.map(\.id) == ["legacy-unscheduled"])
        #expect(appState.calendarReadyWorkItems.isEmpty)
        #expect(appState.workItems.first(where: { $0.id == "legacy-unscheduled" })?.status == .pendingConfirmation)
    }

    @Test("a pending task can be assigned and confirmed without opening details")
    func confirmsWorkItemAfterInlineFieldsAreCompleted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-work-item-confirm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(path: directory.appendingPathComponent("test.sqlite").path)
        try store.upsertPerson(VoiceprintPerson(id: "person-owner", displayName: "负责人"))
        try store.createWorkItem(WorkItem(
            id: "pending-inline",
            title: "确认并排期",
            ownerNameHints: ["原始负责人"],
            sourceDeadlineText: "待确认",
            status: .pendingConfirmation
        ))

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )
        var draft = try #require(appState.workItems.first(where: { $0.id == "pending-inline" }))
        draft.ownerPersonIDs = ["person-owner"]
        draft.ownerNameHints = []
        draft.plannedEndDate = WorkItemDate.normalized(Date().addingTimeInterval(86_400 * 3))
        #expect(appState.updateWorkItem(draft))
        #expect(appState.confirmWorkItem(draft.id))
        #expect(appState.pendingConfirmationWorkItems.isEmpty)
        #expect(appState.calendarReadyWorkItems.map(\.id) == [draft.id])
    }

    @Test("task pool titles can be edited in place and reject an empty title")
    func poolTitleEditPersists() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-work-item-title-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(path: directory.appendingPathComponent("test.sqlite").path)
        try store.createWorkItem(WorkItem(
            id: "pool-title",
            title: "原始标题",
            ownerNameHints: ["原始负责人"],
            status: .pendingConfirmation
        ))

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        var draft = try #require(appState.workItems.first(where: { $0.id == "pool-title" }))
        draft.title = "  行内改后的标题  "
        #expect(appState.updateWorkItem(draft))
        #expect(appState.workItems.first(where: { $0.id == "pool-title" })?.title == "行内改后的标题")
        #expect(try store.loadWorkItems().first(where: { $0.id == "pool-title" })?.title == "行内改后的标题")

        var cleared = try #require(appState.workItems.first(where: { $0.id == "pool-title" }))
        cleared.title = "   "
        #expect(!appState.updateWorkItem(cleared))
        #expect(appState.statusMessage.contains("任务标题不能为空"))
        #expect(appState.workItems.first(where: { $0.id == "pool-title" })?.title == "行内改后的标题")
    }

    @Test("manual tasks without a deadline enter the task pool")
    func manualTaskStartsPendingUntilScheduled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-manual-work-item-pool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(path: directory.appendingPathComponent("test.sqlite").path)
        try store.upsertPerson(VoiceprintPerson(id: "person-me", displayName: "我"))

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )
        #expect(appState.setCurrentUserPerson("person-me"))
        let itemID = try #require(appState.createManualWorkItem())
        #expect(appState.workItems.first(where: { $0.id == itemID })?.status == .pendingConfirmation)
        #expect(appState.pendingConfirmationWorkItems.map(\.id) == [itemID])
        #expect(appState.calendarReadyWorkItems.isEmpty)
    }

    @Test("work item status can be changed directly and persists completion timestamps")
    func workItemStatusCanChangeDirectly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-work-item-status-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(path: directory.appendingPathComponent("test.sqlite").path)
        try store.upsertPerson(VoiceprintPerson(id: "person-owner", displayName: "负责人"))
        let deadline = WorkItemDate.normalized(Date().addingTimeInterval(86_400 * 3))
        let itemID = "direct-status-change"
        try store.createWorkItem(WorkItem(
            id: itemID,
            title: "直接切换状态",
            ownerPersonIDs: ["person-owner"],
            plannedEndDate: deadline,
            status: .notStarted
        ))

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        #expect(appState.setWorkItemStatus(itemID, status: .completed))
        let completed = try #require(appState.workItems.first(where: { $0.id == itemID }))
        #expect(completed.status == .completed)
        #expect(completed.completedAt != nil)
        #expect(try store.loadWorkItems().first(where: { $0.id == itemID })?.status == .completed)

        #expect(appState.setWorkItemStatus(itemID, status: .cancelled))
        let cancelled = try #require(appState.workItems.first(where: { $0.id == itemID }))
        #expect(cancelled.status == .cancelled)
        #expect(cancelled.completedAt == nil)
        #expect(try store.loadWorkItems().first(where: { $0.id == itemID })?.status == .cancelled)

        #expect(appState.setWorkItemStatus(itemID, status: .pendingConfirmation))
        #expect(appState.workItems.first(where: { $0.id == itemID })?.status == .pendingConfirmation)
        #expect(appState.calendarReadyWorkItems.isEmpty)
        #expect(appState.pendingConfirmationWorkItems.map(\.id) == [itemID])

        var invalid = try #require(appState.workItems.first(where: { $0.id == itemID }))
        invalid.status = .completed
        invalid.ownerPersonIDs = []
        #expect(!appState.updateWorkItem(invalid))
        #expect(appState.statusMessage.contains("负责人"))

        invalid.ownerPersonIDs = ["person-owner"]
        invalid.plannedEndDate = nil
        #expect(!appState.updateWorkItem(invalid))
        #expect(appState.statusMessage.contains("截止日期"))
    }
}
