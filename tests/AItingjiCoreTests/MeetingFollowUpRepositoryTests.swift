import Foundation
import Testing
@testable import AItingjiCore

struct MeetingFollowUpRepositoryTests {
    @Test("会后待办按会议替换并保留禅道字段")
    func replaceAndLoad() throws {
        let directory = try TestTemporaryDirectory()
        let database = try Database(path: directory.url.appendingPathComponent("follow-ups.sqlite").path)
        try database.migrate()
        try database.execute(
            "INSERT INTO meetings (id, title, status, capture_source, created_at) VALUES (?, ?, ?, ?, ?)",
            bindings: [.text("meeting-1"), .text("测试会议"), .text("completed"), .text("microphone"), .real(1)]
        )
        let repository = MeetingFollowUpRepository(database: database)
        let record = MeetingFollowUpRecord(
            id: "todo-1", meetingID: "meeting-1", title: "发布版本",
            projectName: "平台项目", executionName: "版本执行", ownerName: "张三",
            plannedStart: "待确认", plannedEnd: "2026-09-20", source: "action",
            status: "matched", projectID: "p1", executionID: "e1", ownerID: "u1",
            taskID: "t1", matchedAt: Date(timeIntervalSince1970: 2)
        )
        try repository.replace(meetingID: "meeting-1", records: [record])
        let loaded = try repository.list(meetingID: "meeting-1")
        #expect(loaded.count == 1)
        #expect(loaded.first?.title == record.title)
        #expect(loaded.first?.projectID == record.projectID)
        #expect(loaded.first?.taskID == record.taskID)
        #expect(loaded.first?.status == record.status)

        let replacement = MeetingFollowUpRecord(id: "todo-2", meetingID: "meeting-1", title: "补充文档")
        try repository.replace(meetingID: "meeting-1", records: [replacement])
        #expect(try repository.list(meetingID: "meeting-1").map(\.id) == ["todo-2"])
    }

    @Test("会后待办表建立会议、状态和任务索引")
    func indexesExist() throws {
        let directory = try TestTemporaryDirectory()
        let database = try Database(path: directory.url.appendingPathComponent("indexes.sqlite").path)
        try database.migrate()
        let rows = try database.query("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_meeting_follow_ups_%'")
        #expect(Set(rows.compactMap { $0["name"]?.stringValue }) == [
            "idx_meeting_follow_ups_meeting_status", "idx_meeting_follow_ups_task"
        ])
    }
}

private struct TestTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("follow-up-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
