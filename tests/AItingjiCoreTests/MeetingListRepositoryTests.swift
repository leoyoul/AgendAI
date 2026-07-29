import Foundation
import Testing
@testable import AItingjiCore

@Test
func meetingTitleCanBeUpdatedAndEmptyTitleIsRejected() throws {
    let path = temporaryMeetingListDatabasePath("title")
    let database = try Database(path: path)
    try database.migrate()
    let meetings = MeetingRepository(database: database)
    try meetings.create(
        Meeting(
            id: "meeting-title",
            title: "原标题",
            createdAt: Date(timeIntervalSince1970: 100)
        )
    )

    try meetings.updateTitle(id: "meeting-title", title: "  新标题  ")
    #expect(throws: MeetingRepositoryError.emptyTitle) {
        try meetings.updateTitle(id: "meeting-title", title: "   ")
    }

    database.close()
    let reopened = try Database(path: path)
    try reopened.migrate()
    let loaded = try MeetingRepository(database: reopened).get(id: "meeting-title")

    #expect(loaded.title == "新标题")
    reopened.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test
func generatedMeetingTitleUsesCASWithoutCreatingConfirmationState() throws {
    let path = temporaryMeetingListDatabasePath("generated-title")
    let database = try Database(path: path)
    try database.migrate()
    let meetings = MeetingRepository(database: database)
    try meetings.create(
        Meeting(
            id: "meeting-generated-title",
            title: "新会议 1",
            status: .done,
            createdAt: Date(timeIntervalSince1970: 100)
        )
    )
    try database.execute(
        """
        UPDATE meetings
        SET handoff_status = 'completed',
            handoff_completed_at = 200,
            handoff_content_hash = 'old-content'
        WHERE id = 'meeting-generated-title'
        """
    )

    let updated = try #require(try meetings.updateGeneratedTitle(
        id: "meeting-generated-title",
        expectedTitle: "新会议 1",
        title: "高速公路项目风险管理方案研讨"
    ))
    #expect(updated.title == "高速公路项目风险管理方案研讨")
    #expect(updated.handoffStatus == .ignored)
    #expect(updated.handoffCompletedAt == nil)
    #expect(updated.handoffContentHash == nil)

    let staleUpdate = try meetings.updateGeneratedTitle(
        id: "meeting-generated-title",
        expectedTitle: "新会议 1",
        title: "不应覆盖"
    )
    #expect(staleUpdate == nil)
    #expect(try meetings.get(id: "meeting-generated-title").title == "高速公路项目风险管理方案研讨")

    database.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test
func meetingArchiveAndPaginationQueriesUseVisibilityAndCreatedAtOrder() throws {
    let path = temporaryMeetingListDatabasePath("archive")
    let database = try Database(path: path)
    try database.migrate()
    let meetings = MeetingRepository(database: database)

    for index in 0..<35 {
        try meetings.create(
            Meeting(
                id: "meeting-\(index)",
                title: "会议 \(index)",
                createdAt: Date(timeIntervalSince1970: Double(index))
            )
        )
    }
    try meetings.setArchived(id: "meeting-34", isArchived: true)
    try meetings.setArchived(id: "meeting-10", isArchived: true)

    let firstPage = try meetings.list(isArchived: false, limit: 30, offset: 0)
    let secondPage = try meetings.list(isArchived: false, limit: 30, offset: 30)
    let archived = try meetings.list(isArchived: true, limit: 30, offset: 0)

    #expect(firstPage.count == 30)
    #expect(firstPage.first?.id == "meeting-33")
    #expect(!firstPage.contains { $0.id == "meeting-34" })
    #expect(!firstPage.contains { $0.id == "meeting-10" })
    #expect(secondPage.map(\.id) == ["meeting-2", "meeting-1", "meeting-0"])
    #expect(archived.map(\.id) == ["meeting-34", "meeting-10"])
    database.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test
func legacyMeetingRowsDefaultToUnarchivedAfterMigration() throws {
    let path = temporaryMeetingListDatabasePath("legacy")
    let database = try Database(path: path)
    try database.migrate()
    // 真实 legacy 库不会有 is_archived 相关索引，所以在模拟 drop column 前先摘掉该索引。
    try database.execute("DROP INDEX IF EXISTS idx_meetings_archived_created")
    try database.execute("DROP INDEX IF EXISTS idx_meetings_handoff_pending")
    try database.execute("ALTER TABLE meetings DROP COLUMN is_archived")
    try database.execute(
        """
        INSERT INTO meetings (
            id, title, status, capture_source, created_at,
            started_at, ended_at, model_snapshot, voiceprint_snapshot
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
            .text("legacy"),
            .text("旧会议"),
            .text("draft"),
            .text("microphone"),
            .real(100),
            .null,
            .null,
            .text("{}"),
            .text("{}")
        ]
    )

    try database.migrate()
    let meeting = try MeetingRepository(database: database).get(id: "legacy")

    #expect(!meeting.isArchived)
    database.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test
func staleMeetingUpsertPreservesExternalHandoffCompletionAndArchive() throws {
    let path = temporaryMeetingListDatabasePath("external-handoff")
    let appDatabase = try Database(path: path)
    try appDatabase.migrate()
    let appRepository = MeetingRepository(database: appDatabase)
    let staleMeeting = Meeting(
        id: "meeting-external-handoff",
        title: "交接会议",
        status: .done,
        createdAt: Date()
    )
    try appRepository.upsert(staleMeeting)

    let externalDatabase = try Database(path: path)
    try externalDatabase.migrate()
    try externalDatabase.execute(
        """
        UPDATE meetings
        SET handoff_status = 'completed',
            handoff_started_at = 100,
            handoff_completed_at = 200,
            handoff_content_hash = 'hash-v1',
            handoff_error = NULL,
            is_archived = 1
        WHERE id = ?
        """,
        bindings: [.text(staleMeeting.id)]
    )

    try? appRepository.upsert(staleMeeting)
    let loaded = try appRepository.get(id: staleMeeting.id)

    #expect(loaded.isArchived)
    #expect(loaded.handoffStatus == .completed)
    #expect(loaded.handoffStartedAt == Date(timeIntervalSince1970: 100))
    #expect(loaded.handoffCompletedAt == Date(timeIntervalSince1970: 200))
    #expect(loaded.handoffContentHash == "hash-v1")
    externalDatabase.close()
    appDatabase.close()
    try? FileManager.default.removeItem(atPath: path)
}

private func temporaryMeetingListDatabasePath(_ name: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("AItingji-\(UUID().uuidString)-\(name)")
        .appendingPathExtension("sqlite")
        .path
}
