import Foundation

/// 会后待办的持久化 DTO。它刻意只使用基础类型，避免 Core 依赖 App 层的禅道模型。
public struct MeetingFollowUpRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var meetingID: String
    public var title: String
    public var projectName: String
    public var executionName: String
    public var ownerName: String
    public var plannedStart: String
    public var plannedEnd: String
    public var source: String
    public var status: String
    public var projectID: String?
    public var executionID: String?
    public var ownerID: String?
    public var taskID: String?
    public var errorMessage: String?
    public var matchedAt: Date?
    public var handedOffAt: Date?
    public var updatedAt: Date

    public init(
        id: String,
        meetingID: String,
        title: String,
        projectName: String = "",
        executionName: String = "",
        ownerName: String = "",
        plannedStart: String = "",
        plannedEnd: String = "",
        source: String = "action",
        status: String = "pending",
        projectID: String? = nil,
        executionID: String? = nil,
        ownerID: String? = nil,
        taskID: String? = nil,
        errorMessage: String? = nil,
        matchedAt: Date? = nil,
        handedOffAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.title = title
        self.projectName = projectName
        self.executionName = executionName
        self.ownerName = ownerName
        self.plannedStart = plannedStart
        self.plannedEnd = plannedEnd
        self.source = source
        self.status = status
        self.projectID = projectID
        self.executionID = executionID
        self.ownerID = ownerID
        self.taskID = taskID
        self.errorMessage = errorMessage
        self.matchedAt = matchedAt
        self.handedOffAt = handedOffAt
        self.updatedAt = updatedAt
    }
}

public struct MeetingFollowUpRepository: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func list(meetingID: String) throws -> [MeetingFollowUpRecord] {
        try database.query(
            """
            SELECT * FROM meeting_follow_ups
            WHERE meeting_id = ?
            ORDER BY updated_at DESC, id
            """,
            bindings: [.text(meetingID)]
        ).map(decode)
    }

    /// 替换一次匹配结果。事务保证失败时不会留下半批数据。
    public func replace(meetingID: String, records: [MeetingFollowUpRecord]) throws {
        try database.transaction {
            try database.execute("DELETE FROM meeting_follow_ups WHERE meeting_id = ?", bindings: [.text(meetingID)])
            for record in records {
                try upsert(record)
            }
        }
    }

    public func upsert(_ record: MeetingFollowUpRecord) throws {
        try database.execute(
            """
            INSERT INTO meeting_follow_ups (
                id, meeting_id, title, project_name, execution_name, owner_name,
                planned_start, planned_end, source, status, project_id, execution_id,
                owner_id, task_id, error_message, matched_at, handed_off_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                meeting_id = excluded.meeting_id,
                title = excluded.title,
                project_name = excluded.project_name,
                execution_name = excluded.execution_name,
                owner_name = excluded.owner_name,
                planned_start = excluded.planned_start,
                planned_end = excluded.planned_end,
                source = excluded.source,
                status = excluded.status,
                project_id = excluded.project_id,
                execution_id = excluded.execution_id,
                owner_id = excluded.owner_id,
                task_id = excluded.task_id,
                error_message = excluded.error_message,
                matched_at = excluded.matched_at,
                handed_off_at = excluded.handed_off_at,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(record.id), .text(record.meetingID), .text(record.title),
                .text(record.projectName), .text(record.executionName), .text(record.ownerName),
                .text(record.plannedStart), .text(record.plannedEnd), .text(record.source),
                .text(record.status), record.projectID.map(SQLiteValue.text) ?? .null,
                record.executionID.map(SQLiteValue.text) ?? .null, record.ownerID.map(SQLiteValue.text) ?? .null,
                record.taskID.map(SQLiteValue.text) ?? .null, record.errorMessage.map(SQLiteValue.text) ?? .null,
                record.matchedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                record.handedOffAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .real(record.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    private func decode(_ row: [String: SQLiteValue]) -> MeetingFollowUpRecord {
        func date(_ key: String) -> Date? {
            row[key]?.doubleValue.map(Date.init(timeIntervalSince1970:))
        }
        return MeetingFollowUpRecord(
            id: row["id"]?.stringValue ?? "",
            meetingID: row["meeting_id"]?.stringValue ?? "",
            title: row["title"]?.stringValue ?? "",
            projectName: row["project_name"]?.stringValue ?? "",
            executionName: row["execution_name"]?.stringValue ?? "",
            ownerName: row["owner_name"]?.stringValue ?? "",
            plannedStart: row["planned_start"]?.stringValue ?? "",
            plannedEnd: row["planned_end"]?.stringValue ?? "",
            source: row["source"]?.stringValue ?? "action",
            status: row["status"]?.stringValue ?? "pending",
            projectID: row["project_id"]?.stringValue,
            executionID: row["execution_id"]?.stringValue,
            ownerID: row["owner_id"]?.stringValue,
            taskID: row["task_id"]?.stringValue,
            errorMessage: row["error_message"]?.stringValue,
            matchedAt: date("matched_at"),
            handedOffAt: date("handed_off_at"),
            updatedAt: date("updated_at") ?? Date(timeIntervalSince1970: 0)
        )
    }
}
