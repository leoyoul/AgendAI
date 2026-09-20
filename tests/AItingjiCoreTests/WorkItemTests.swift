import Foundation
import Testing
@testable import AItingjiCore

@Test
func workItemStatusTransitionsAreUnrestrictedAndOverdueRule() {
    for source in WorkItemStatus.allCases {
        for target in WorkItemStatus.allCases {
            #expect(source.canTransition(to: target))
        }
    }

    let calendar = testCalendar()
    let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
    let overdue = WorkItem(
        title: "逾期任务",
        plannedEndDate: yesterday,
        status: .inProgress
    )
    #expect(overdue.isOverdue(calendar: calendar))
    #expect(!WorkItem(title: "已完成", plannedEndDate: yesterday, status: .completed).isOverdue(calendar: calendar))
    #expect(!WorkItem(title: "已取消", plannedEndDate: yesterday, status: .cancelled).isOverdue(calendar: calendar))
}

@Test
func workItemCalendarReadinessRequiresConfirmationFields() {
    let date = makeDate(year: 2026, month: 9, day: 16, calendar: testCalendar())
    let ready = WorkItem(
        title: "可排期任务",
        ownerPersonIDs: ["person-1"],
        plannedEndDate: date,
        status: .notStarted
    )
    #expect(ready.isCalendarReady)
    #expect(!ready.needsConfirmation)

    #expect(!WorkItem(
        title: "待确认任务",
        ownerPersonIDs: ["person-1"],
        plannedEndDate: date,
        status: .pendingConfirmation
    ).isCalendarReady)
    #expect(!WorkItem(
        title: "缺少负责人",
        plannedEndDate: date,
        status: .notStarted
    ).isCalendarReady)
    #expect(!WorkItem(
        title: "缺少截止日期",
        ownerPersonIDs: ["person-1"],
        status: .notStarted
    ).isCalendarReady)
}

@Test
func workItemDateParserSupportsCommonFormatsAndRejectsInvalidDates() {
    let calendar = testCalendar()
    let reference = makeDate(year: 2026, month: 9, day: 16, calendar: calendar)

    #expect(WorkItemDate.key(WorkItemDateParser.parse("2026年10月2日", referenceDate: reference, calendar: calendar)!, calendar: calendar) == "2026-10-02")
    #expect(WorkItemDate.key(WorkItemDateParser.parse("10月3日截止", referenceDate: reference, calendar: calendar)!, calendar: calendar) == "2026-10-03")
    #expect(WorkItemDate.key(WorkItemDateParser.parse("2026/10/04（待确认）", referenceDate: reference, calendar: calendar)!, calendar: calendar) == "2026-10-04")
    #expect(WorkItemDate.key(WorkItemDateParser.parse("10/05 截止", referenceDate: reference, calendar: calendar)!, calendar: calendar) == "2026-10-05")
    #expect(WorkItemDateParser.parse("2026年2月30日", referenceDate: reference, calendar: calendar) == nil)
    #expect(WorkItemDateParser.parse("待确认", referenceDate: reference, calendar: calendar) == nil)
}

@Test
func workItemDefaultDeadlineIsSevenDaysAfterStartAcrossMonthAndYear() {
    let calendar = testCalendar()
    let normalStart = makeDate(year: 2026, month: 9, day: 16, calendar: calendar)
    let yearEndStart = makeDate(year: 2026, month: 12, day: 28, calendar: calendar)

    #expect(WorkItemDate.key(WorkItemDate.addingDays(normalStart, 7, calendar: calendar), calendar: calendar) == "2026-09-23")
    #expect(WorkItemDate.key(WorkItemDate.addingDays(yearEndStart, 7, calendar: calendar), calendar: calendar) == "2027-01-04")
}

@Test
func workItemRepositoryRoundTripsEditableFieldsAndRejectsInvalidDateRange() throws {
    let database = try makeWorkItemDatabase()
    defer { database.close() }
    let repository = WorkItemRepository(database: database)
    let calendar = testCalendar()
    let start = makeDate(year: 2026, month: 9, day: 16, calendar: calendar)
    let end = makeDate(year: 2026, month: 9, day: 20, calendar: calendar)
    let item = WorkItem(
        id: "work-item-round-trip",
        title: "准备发布说明",
        detail: "整理变更内容",
        deliverable: "发布说明文档",
        acceptanceCriteria: "产品确认",
        ownerPersonIDs: ["person-1", "person-2"],
        ownerNameHints: ["未匹配同事"],
        sourceDeadlineText: "9月20日前",
        plannedStartDate: start,
        plannedEndDate: end,
        status: .inProgress,
        priority: .high,
        tags: ["发布", "产品"],
        completionNote: "已完成初稿",
        completedAt: nil,
        sourceMeetingID: "meeting-1",
        sourceMeetingTitle: "版本评审",
        source: .meetingMinutes,
        createdAt: start,
        updatedAt: end
    )

    try repository.create(item)
    let loaded = try #require(try repository.get(id: item.id))
    #expect(loaded.title == item.title)
    #expect(loaded.ownerPersonIDs == item.ownerPersonIDs)
    #expect(loaded.ownerNameHints == item.ownerNameHints)
    #expect(loaded.plannedStartDate == start)
    #expect(loaded.plannedEndDate == end)
    #expect(loaded.priority == .high)
    #expect(loaded.tags == item.tags)
    #expect(loaded.source == .meetingMinutes)

    let invalid = WorkItem(
        id: "invalid-range",
        title: "日期错误",
        plannedStartDate: end,
        plannedEndDate: start
    )
    #expect(throws: WorkItemRepositoryError.invalidDateRange) {
        try repository.create(invalid)
    }
}

@Test
func generatedWorkItemsMergeIdempotentlyAndPreserveUserEdits() throws {
    let database = try makeWorkItemDatabase()
    defer { database.close() }
    let repository = WorkItemRepository(database: database)
    let calendar = testCalendar()
    let meetingDate = makeDate(year: 2026, month: 9, day: 16, calendar: calendar)
    let deadline = makeDate(year: 2026, month: 9, day: 20, calendar: calendar)
    let generated = WorkItem(
        id: "generated-minutes-id",
        title: "确认发布范围",
        ownerPersonIDs: ["person-1"],
        plannedStartDate: meetingDate,
        plannedEndDate: deadline,
        status: .pendingConfirmation,
        sourceMeetingID: "meeting-1",
        sourceMeetingTitle: "版本评审",
        source: .meetingMinutes
    )
    let minutesOrigin = WorkItemOrigin(
        id: "origin-minutes",
        workItemID: generated.id,
        source: .meetingMinutes,
        sourceKey: "minutes:meeting-1:action-1",
        meetingID: "meeting-1",
        meetingTitle: "版本评审",
        rawTitle: generated.title,
        rawOwnerNames: ["张三"],
        rawDeadline: "9月20日"
    )

    let first = try repository.mergeGeneratedWorkItems([
        WorkItemImportCandidate(item: generated, origin: minutesOrigin)
    ])
    #expect(first.map(\.id) == [generated.id])

    var edited = generated
    edited.title = "用户已改标题"
    edited.status = .inProgress
    edited.priority = .high
    edited.tags = ["重点"]
    edited.updatedAt = deadline
    try repository.update(edited)

    let analysisOrigin = WorkItemOrigin(
        id: "origin-analysis",
        workItemID: "generated-analysis-id",
        source: .meetingAnalysis,
        sourceKey: "analysis:meeting-1:todo-1",
        meetingID: "meeting-1",
        meetingTitle: "版本评审",
        rawTitle: generated.title
    )
    let analysisCandidate = WorkItemImportCandidate(
        item: WorkItem(
            id: "generated-analysis-id",
            title: generated.title,
            ownerPersonIDs: generated.ownerPersonIDs,
            plannedStartDate: meetingDate,
            plannedEndDate: deadline,
            status: .pendingConfirmation,
            sourceMeetingID: "meeting-1",
            sourceMeetingTitle: "版本评审",
            source: .meetingAnalysis
        ),
        origin: analysisOrigin
    )
    _ = try repository.mergeGeneratedWorkItems([analysisCandidate])
    _ = try repository.mergeGeneratedWorkItems([WorkItemImportCandidate(item: generated, origin: minutesOrigin)])

    let loaded = try #require(try repository.get(id: generated.id))
    #expect(loaded.title == "用户已改标题")
    #expect(loaded.status == .inProgress)
    #expect(loaded.priority == .high)
    #expect(loaded.tags == ["重点"])
    #expect((try repository.list()).count == 1)
    #expect((try repository.listOrigins(workItemID: generated.id)).count == 2)
}

@Test
func deletingMeetingDetachesSourceButKeepsWorkItemAndSnapshot() throws {
    let database = try makeWorkItemDatabase()
    defer { database.close() }
    let repository = WorkItemRepository(database: database)
    let item = WorkItem(
        id: "detached-item",
        title: "跟进会议结论",
        sourceMeetingID: "meeting-to-delete",
        sourceMeetingTitle: "会议标题快照",
        source: .meetingMinutes
    )
    let origin = WorkItemOrigin(
        id: "detached-origin",
        workItemID: item.id,
        source: .meetingMinutes,
        sourceKey: "minutes:meeting-to-delete:action-1",
        meetingID: "meeting-to-delete",
        meetingTitle: "会议标题快照",
        rawTitle: item.title
    )
    try repository.create(item, origins: [origin])
    try repository.detachMeetingSource(meetingID: "meeting-to-delete")

    let loaded = try #require(try repository.get(id: item.id))
    let loadedOrigin = try #require(try repository.listOrigins(workItemID: item.id).first)
    #expect(loaded.sourceMeetingID == nil)
    #expect(loaded.sourceMeetingTitle == "会议标题快照")
    #expect(loadedOrigin.meetingID == nil)
    #expect(loadedOrigin.meetingTitle == "会议标题快照")
}

@Test
func batchDeletingWorkItemsRemovesOriginsAndRollsBackWhenAnIDIsMissing() throws {
    let database = try makeWorkItemDatabase()
    defer { database.close() }
    let repository = WorkItemRepository(database: database)
    let first = WorkItem(id: "batch-first", title: "第一项")
    let second = WorkItem(id: "batch-second", title: "第二项")
    let firstOrigin = WorkItemOrigin(
        id: "batch-origin-first",
        workItemID: first.id,
        source: .meetingMinutes,
        sourceKey: "batch:first",
        rawTitle: first.title
    )
    let secondOrigin = WorkItemOrigin(
        id: "batch-origin-second",
        workItemID: second.id,
        source: .meetingAnalysis,
        sourceKey: "batch:second",
        rawTitle: second.title
    )

    try repository.create(first, origins: [firstOrigin])
    try repository.create(second, origins: [secondOrigin])

    #expect(throws: WorkItemRepositoryError.missingWorkItem) {
        try repository.delete(ids: [first.id, "missing-batch-item"])
    }
    #expect(try repository.get(id: first.id) != nil)
    #expect(try repository.get(id: second.id) != nil)

    try repository.delete(ids: [first.id, first.id, second.id])
    #expect(try repository.list().isEmpty)
    #expect(try repository.listOrigins(workItemID: first.id).isEmpty)
    #expect(try repository.listOrigins(workItemID: second.id).isEmpty)

    try repository.delete(ids: [])
}

private func makeWorkItemDatabase() throws -> Database {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-tingji-work-items-\(UUID().uuidString).sqlite")
        .path
    let database = try Database(path: path)
    try database.migrate()
    return database
}

private func testCalendar() -> Calendar {
    Calendar.current
}

private func makeDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day))!
}
