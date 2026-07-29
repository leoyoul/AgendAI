import Foundation

public enum MeetingAgentRepositoryError: Error, Equatable, Sendable {
    case stateConflict
    case resultConflict
    case identityMismatch
    case invalidRecord
}

public struct MeetingAgentJobRepository: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func create(_ job: MeetingAgentJob) throws {
        guard job.status == .submitting else {
            throw MeetingAgentRepositoryError.stateConflict
        }
        try database.execute(
            """
            INSERT INTO meeting_agent_jobs (
                id, meeting_id, request_hash, provider, status, analysis_goal,
                result_relative_path, error_code, error_message,
                created_at, updated_at, completed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(job.id),
                .text(job.meetingID),
                .text(job.requestHash),
                .text(job.provider),
                .text(job.status.rawValue),
                .text(job.analysisGoal),
                job.resultRelativePath.map(SQLiteValue.text) ?? .null,
                job.errorCode.map(SQLiteValue.text) ?? .null,
                job.errorMessage.map(SQLiteValue.text) ?? .null,
                .real(job.createdAt.timeIntervalSince1970),
                .real(job.updatedAt.timeIntervalSince1970),
                job.completedAt.map { .real($0.timeIntervalSince1970) } ?? .null
            ]
        )
    }

    @discardableResult
    public func transition(
        id: MeetingAgentJob.ID,
        from source: MeetingAgentJobStatus,
        to target: MeetingAgentJobStatus,
        expectedUpdatedAt: Date,
        updatedAt: Date
    ) throws -> Bool {
        guard target != .failed, Self.allowedTransitions[source]?.contains(target) == true else {
            throw MeetingAgentRepositoryError.stateConflict
        }
        let completedAt: SQLiteValue
        switch target {
        case .ready, .failed, .cancelled:
            completedAt = .real(updatedAt.timeIntervalSince1970)
        default:
            completedAt = .null
        }
        let changes = try database.executeReturningChanges(
            """
            UPDATE meeting_agent_jobs
            SET status = ?, error_code = NULL, error_message = NULL,
                updated_at = ?, completed_at = ?
            WHERE id = ? AND status = ? AND updated_at = ?
            """,
            bindings: [
                .text(target.rawValue),
                .real(updatedAt.timeIntervalSince1970),
                completedAt,
                .text(id),
                .text(source.rawValue),
                .real(expectedUpdatedAt.timeIntervalSince1970)
            ]
        )
        return changes == 1
    }

    @discardableResult
    public func markFailed(
        id: MeetingAgentJob.ID,
        from source: MeetingAgentJobStatus,
        expectedUpdatedAt: Date,
        errorCode: String,
        errorMessage: String,
        updatedAt: Date
    ) throws -> Bool {
        guard Self.allowedTransitions[source]?.contains(.failed) == true else {
            throw MeetingAgentRepositoryError.stateConflict
        }
        let truncatedMessage = String(errorMessage.prefix(2_000))
        let changes = try database.executeReturningChanges(
            """
            UPDATE meeting_agent_jobs
            SET status = 'failed', error_code = ?, error_message = ?,
                updated_at = ?, completed_at = ?
            WHERE id = ? AND status = ? AND updated_at = ?
            """,
            bindings: [
                .text(errorCode),
                .text(truncatedMessage),
                .real(updatedAt.timeIntervalSince1970),
                .real(updatedAt.timeIntervalSince1970),
                .text(id),
                .text(source.rawValue),
                .real(expectedUpdatedAt.timeIntervalSince1970)
            ]
        )
        return changes == 1
    }

    private static let allowedTransitions: [MeetingAgentJobStatus: Set<MeetingAgentJobStatus>] = [
        .submitting: [.queued, .failed, .cancelled],
        .queued: [.running, .importing, .failed, .cancelled],
        .running: [.importing, .failed, .cancelled],
        .importing: [.failed],
        .failed: [.queued],
        .ready: [],
        .cancelled: []
    ]

    public func get(id: MeetingAgentJob.ID) throws -> MeetingAgentJob? {
        try database.query(
            "SELECT * FROM meeting_agent_jobs WHERE id = ?",
            bindings: [.text(id)]
        ).first.map(decode)
    }

    public func list(meetingID: Meeting.ID) throws -> [MeetingAgentJob] {
        try database.query(
            """
            SELECT * FROM meeting_agent_jobs
            WHERE meeting_id = ?
            ORDER BY created_at DESC, id DESC
            """,
            bindings: [.text(meetingID)]
        ).map(decode)
    }

    private func decode(_ row: [String: SQLiteValue]) throws -> MeetingAgentJob {
        guard
            let statusValue = row["status"]?.stringValue,
            let status = MeetingAgentJobStatus(rawValue: statusValue),
            let createdAt = row["created_at"]?.doubleValue,
            let updatedAt = row["updated_at"]?.doubleValue
        else {
            throw MeetingAgentRepositoryError.invalidRecord
        }
        return MeetingAgentJob(
            id: row["id"]?.stringValue ?? "",
            meetingID: row["meeting_id"]?.stringValue ?? "",
            requestHash: row["request_hash"]?.stringValue ?? "",
            provider: row["provider"]?.stringValue ?? "",
            status: status,
            analysisGoal: row["analysis_goal"]?.stringValue ?? "",
            resultRelativePath: row["result_relative_path"]?.stringValue,
            errorCode: row["error_code"]?.stringValue,
            errorMessage: row["error_message"]?.stringValue,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            completedAt: row["completed_at"]?.doubleValue.map(Date.init(timeIntervalSince1970:))
        )
    }
}

public struct MeetingAgentResultRepository: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func create(_ result: MeetingAgentResult) throws {
        try database.execute(
            """
            INSERT INTO meeting_agent_results (
                id, job_id, meeting_id, manifest_relative_path,
                report_relative_path, manifest_sha256, imported_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(result.id),
                .text(result.jobID),
                .text(result.meetingID),
                .text(result.manifestRelativePath),
                .text(result.reportRelativePath),
                .text(result.manifestSHA256),
                .real(result.importedAt.timeIntervalSince1970)
            ]
        )
    }

    public func get(jobID: MeetingAgentJob.ID) throws -> MeetingAgentResult? {
        try database.query(
            "SELECT * FROM meeting_agent_results WHERE job_id = ?",
            bindings: [.text(jobID)]
        ).first.map(decode)
    }

    func representsSamePackage(_ lhs: MeetingAgentResult, _ rhs: MeetingAgentResult) -> Bool {
        lhs.id == rhs.id
            && lhs.jobID == rhs.jobID
            && lhs.meetingID == rhs.meetingID
            && lhs.manifestRelativePath == rhs.manifestRelativePath
            && lhs.reportRelativePath == rhs.reportRelativePath
            && lhs.manifestSHA256.caseInsensitiveCompare(rhs.manifestSHA256) == .orderedSame
    }

    private func decode(_ row: [String: SQLiteValue]) throws -> MeetingAgentResult {
        guard let importedAt = row["imported_at"]?.doubleValue else {
            throw MeetingAgentRepositoryError.invalidRecord
        }
        return MeetingAgentResult(
            id: row["id"]?.stringValue ?? "",
            jobID: row["job_id"]?.stringValue ?? "",
            meetingID: row["meeting_id"]?.stringValue ?? "",
            manifestRelativePath: row["manifest_relative_path"]?.stringValue ?? "",
            reportRelativePath: row["report_relative_path"]?.stringValue ?? "",
            manifestSHA256: row["manifest_sha256"]?.stringValue ?? "",
            importedAt: Date(timeIntervalSince1970: importedAt)
        )
    }
}

public struct MeetingTodoRepository: Sendable {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: Database) {
        self.database = database
    }

    public func create(_ todo: MeetingTodo) throws {
        let evidenceData = try encoder.encode(todo.evidence)
        try database.execute(
            """
            INSERT INTO meeting_todos (
                id, job_id, meeting_id, title, detail, owner, deadline, deliverable,
                acceptance_criteria, evidence_json, confirmation_status, proposed_workflow,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(todo.todoID),
                .text(todo.jobID),
                .text(todo.meetingID),
                .text(todo.title),
                .text(todo.detail),
                todo.owner.map(SQLiteValue.text) ?? .null,
                todo.deadline.map(SQLiteValue.text) ?? .null,
                todo.deliverable.map(SQLiteValue.text) ?? .null,
                todo.acceptanceCriteria.map(SQLiteValue.text) ?? .null,
                .text(String(decoding: evidenceData, as: UTF8.self)),
                .text(todo.confirmationStatus.rawValue),
                .text(todo.proposedWorkflow.rawValue),
                .real(todo.createdAt.timeIntervalSince1970),
                .real(todo.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    public func list(meetingID: Meeting.ID) throws -> [MeetingTodo] {
        try database.query(
            """
            SELECT * FROM meeting_todos
            WHERE meeting_id = ?
            ORDER BY created_at, id
            """,
            bindings: [.text(meetingID)]
        ).map(decode)
    }

    public func count(jobID: MeetingAgentJob.ID) throws -> Int {
        let rows = try database.query(
            "SELECT COUNT(*) AS count FROM meeting_todos WHERE job_id = ?",
            bindings: [.text(jobID)]
        )
        return rows.first?["count"]?.intValue ?? 0
    }

    private func decode(_ row: [String: SQLiteValue]) throws -> MeetingTodo {
        guard
            let confirmationValue = row["confirmation_status"]?.stringValue,
            let confirmationStatus = MeetingTodoConfirmationStatus(rawValue: confirmationValue),
            let workflowValue = row["proposed_workflow"]?.stringValue,
            let proposedWorkflow = MeetingTodoWorkflow(rawValue: workflowValue),
            let createdAt = row["created_at"]?.doubleValue,
            let updatedAt = row["updated_at"]?.doubleValue
        else {
            throw MeetingAgentRepositoryError.invalidRecord
        }
        let evidenceJSON = row["evidence_json"]?.stringValue ?? "[]"
        let evidence = try decoder.decode([MeetingTodoEvidence].self, from: Data(evidenceJSON.utf8))
        return MeetingTodo(
            id: row["id"]?.stringValue ?? "",
            jobID: row["job_id"]?.stringValue ?? "",
            meetingID: row["meeting_id"]?.stringValue ?? "",
            title: row["title"]?.stringValue ?? "",
            detail: row["detail"]?.stringValue ?? "",
            owner: row["owner"]?.stringValue,
            deadline: row["deadline"]?.stringValue,
            deliverable: row["deliverable"]?.stringValue,
            acceptanceCriteria: row["acceptance_criteria"]?.stringValue,
            evidence: evidence,
            confirmationStatus: confirmationStatus,
            proposedWorkflow: proposedWorkflow,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}

public struct MeetingAgentChatRepository: Sendable {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: Database) {
        self.database = database
    }

    public func upsert(_ message: MeetingAgentChatMessage) throws {
        guard !message.id.isEmpty, !message.meetingID.isEmpty else {
            throw MeetingAgentRepositoryError.invalidRecord
        }
        try database.execute(
            """
            INSERT INTO meeting_agent_chat_messages (
                id, meeting_id, role, content, reasoning, activity_json, timeline_json,
                status, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                content = excluded.content,
                reasoning = excluded.reasoning,
                activity_json = excluded.activity_json,
                timeline_json = excluded.timeline_json,
                status = excluded.status,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(message.id),
                .text(message.meetingID),
                .text(message.role.rawValue),
                .text(message.content),
                .text(message.reasoning),
                .text(String(decoding: try encoder.encode(message.activity), as: UTF8.self)),
                .text(String(decoding: try encoder.encode(message.timeline), as: UTF8.self)),
                .text(message.status.rawValue),
                .real(message.createdAt.timeIntervalSince1970),
                .real(message.updatedAt.timeIntervalSince1970)
            ]
        )
    }

    public func list(meetingID: Meeting.ID) throws -> [MeetingAgentChatMessage] {
        try database.query(
            """
            SELECT * FROM meeting_agent_chat_messages
            WHERE meeting_id = ?
            ORDER BY created_at ASC, rowid ASC
            """,
            bindings: [.text(meetingID)]
        ).map(decode)
    }

    public func listAllGroupedByMeeting() throws -> [Meeting.ID: [MeetingAgentChatMessage]] {
        let messages = try database.query(
            """
            SELECT * FROM meeting_agent_chat_messages
            ORDER BY meeting_id ASC, created_at ASC, rowid ASC
            """
        ).map(decode)
        return Dictionary(grouping: messages, by: \.meetingID)
    }

    private func decode(_ row: [String: SQLiteValue]) throws -> MeetingAgentChatMessage {
        guard let roleValue = row["role"]?.stringValue,
              let role = MeetingAgentChatRole(rawValue: roleValue),
              let statusValue = row["status"]?.stringValue,
              let status = MeetingAgentChatStatus(rawValue: statusValue),
              let createdAt = row["created_at"]?.doubleValue,
              let updatedAt = row["updated_at"]?.doubleValue else {
            throw MeetingAgentRepositoryError.invalidRecord
        }
        let activityJSON = row["activity_json"]?.stringValue ?? "[]"
        let activity = try decoder.decode([String].self, from: Data(activityJSON.utf8))
        let timelineJSON = row["timeline_json"]?.stringValue ?? "[]"
        let timeline = try decoder.decode([MeetingAgentTurnSegment].self, from: Data(timelineJSON.utf8))
        return MeetingAgentChatMessage(
            id: row["id"]?.stringValue ?? "",
            meetingID: row["meeting_id"]?.stringValue ?? "",
            role: role,
            content: row["content"]?.stringValue ?? "",
            reasoning: row["reasoning"]?.stringValue ?? "",
            activity: activity,
            timeline: timeline,
            status: status,
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }
}
