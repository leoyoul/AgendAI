import AItingjiCore
import Foundation
import Testing

@Suite("Meeting Agent repositories")
struct MeetingAgentRepositoryTests {
    @Test("job lifecycle uses one identity, CAS transitions, truncates errors, and lists newest first")
    func jobLifecycle() throws {
        let fixture = try StoreFixture("job-lifecycle")
        defer { fixture.close() }
        try fixture.insertMeeting(id: "meeting-a")

        let older = fixture.job(id: "request-and-job-1", meetingID: "meeting-a", createdAt: 10)
        let newer = fixture.job(id: "request-and-job-2", meetingID: "meeting-a", createdAt: 20)
        try fixture.store.createMeetingAgentJob(older)
        try fixture.store.createMeetingAgentJob(newer)

        #expect(try fixture.store.loadMeetingAgentJob(id: older.id) == older)
        #expect(try fixture.store.loadMeetingAgentJobs(meetingID: "meeting-a").map(\.id) == [newer.id, older.id])
        #expect(try fixture.store.transitionMeetingAgentJob(
            id: older.id,
            from: .submitting,
            to: .queued,
            expectedUpdatedAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        ))
        #expect(!(try fixture.store.transitionMeetingAgentJob(
            id: older.id,
            from: .submitting,
            to: .queued,
            expectedUpdatedAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 12)
        )))
        #expect(try fixture.store.markMeetingAgentJobFailed(
            id: older.id,
            from: .queued,
            expectedUpdatedAt: Date(timeIntervalSince1970: 11),
            errorCode: "PROVIDER_FAILED",
            errorMessage: String(repeating: "错", count: 2_100),
            updatedAt: Date(timeIntervalSince1970: 13)
        ))

        let failed = try #require(try fixture.store.loadMeetingAgentJob(id: older.id))
        #expect(failed.id == "request-and-job-1")
        #expect(failed.status == .failed)
        #expect(failed.errorCode == "PROVIDER_FAILED")
        #expect(failed.errorMessage?.count == 2_000)
        #expect(failed.updatedAt == Date(timeIntervalSince1970: 13))
        #expect(failed.completedAt == Date(timeIntervalSince1970: 13))

        #expect(try fixture.store.transitionMeetingAgentJob(
            id: older.id,
            from: .failed,
            to: .queued,
            expectedUpdatedAt: Date(timeIntervalSince1970: 13),
            updatedAt: Date(timeIntervalSince1970: 14)
        ))
        let retried = try #require(try fixture.store.loadMeetingAgentJob(id: older.id))
        #expect(retried.status == .queued)
        #expect(retried.errorCode == nil)
        #expect(retried.errorMessage == nil)
        #expect(retried.completedAt == nil)

        #expect(!(try fixture.store.markMeetingAgentJobFailed(
            id: older.id,
            from: .queued,
            expectedUpdatedAt: Date(timeIntervalSince1970: 11),
            errorCode: "LATE_FAILURE",
            errorMessage: "迟到的旧失败",
            updatedAt: Date(timeIntervalSince1970: 15)
        )))
        #expect(try fixture.store.loadMeetingAgentJob(id: older.id) == retried)
    }

    @Test("job creation and transitions enforce the lifecycle graph")
    func lifecycleGraph() throws {
        let fixture = try StoreFixture("lifecycle-graph")
        defer { fixture.close() }
        try fixture.insertMeeting(id: "meeting-graph")
        var invalidInitial = fixture.job(id: "job-invalid-initial", meetingID: "meeting-graph")
        invalidInitial.status = .queued
        #expect(throws: MeetingAgentRepositoryError.stateConflict) {
            try fixture.store.createMeetingAgentJob(invalidInitial)
        }

        let job = fixture.job(id: "job-graph", meetingID: "meeting-graph")
        try fixture.store.createMeetingAgentJob(job)
        #expect(throws: MeetingAgentRepositoryError.stateConflict) {
            try fixture.store.transitionMeetingAgentJob(
                id: job.id,
                from: .submitting,
                to: .running,
                expectedUpdatedAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 11)
            )
        }
        #expect(try fixture.store.transitionMeetingAgentJob(
            id: job.id,
            from: .submitting,
            to: .queued,
            expectedUpdatedAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        ))
        #expect(throws: MeetingAgentRepositoryError.stateConflict) {
            try fixture.store.transitionMeetingAgentJob(
                id: job.id,
                from: .queued,
                to: .ready,
                expectedUpdatedAt: Date(timeIntervalSince1970: 11),
                updatedAt: Date(timeIntervalSince1970: 12)
            )
        }
        #expect(try fixture.store.transitionMeetingAgentJob(
            id: job.id,
            from: .queued,
            to: .running,
            expectedUpdatedAt: Date(timeIntervalSince1970: 11),
            updatedAt: Date(timeIntervalSince1970: 12)
        ))
        #expect(try fixture.store.transitionMeetingAgentJob(
            id: job.id,
            from: .running,
            to: .importing,
            expectedUpdatedAt: Date(timeIntervalSince1970: 12),
            updatedAt: Date(timeIntervalSince1970: 13)
        ))
        #expect(throws: MeetingAgentRepositoryError.stateConflict) {
            try fixture.store.transitionMeetingAgentJob(
                id: job.id,
                from: .importing,
                to: .ready,
                expectedUpdatedAt: Date(timeIntervalSince1970: 13),
                updatedAt: Date(timeIntervalSince1970: 14)
            )
        }
        #expect(throws: MeetingAgentRepositoryError.stateConflict) {
            try fixture.store.transitionMeetingAgentJob(
                id: job.id,
                from: .importing,
                to: .failed,
                expectedUpdatedAt: Date(timeIntervalSince1970: 13),
                updatedAt: Date(timeIntervalSince1970: 14)
            )
        }

        let cancelled = fixture.job(id: "job-cancelled", meetingID: "meeting-graph")
        try fixture.store.createMeetingAgentJob(cancelled)
        #expect(try fixture.store.transitionMeetingAgentJob(
            id: cancelled.id,
            from: .submitting,
            to: .cancelled,
            expectedUpdatedAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        ))
        #expect(throws: MeetingAgentRepositoryError.stateConflict) {
            try fixture.store.transitionMeetingAgentJob(
                id: cancelled.id,
                from: .cancelled,
                to: .queued,
                expectedUpdatedAt: Date(timeIntervalSince1970: 11),
                updatedAt: Date(timeIntervalSince1970: 12)
            )
        }
    }

    @Test("old attempts cannot advance a retried job")
    func retryRejectsABATransition() throws {
        let fixture = try StoreFixture("aba-transition")
        defer { fixture.close() }
        try fixture.insertMeeting(id: "meeting-aba")
        let job = fixture.job(id: "job-aba", meetingID: "meeting-aba")
        try fixture.store.createMeetingAgentJob(job)
        #expect(try fixture.store.transitionMeetingAgentJob(
            id: job.id, from: .submitting, to: .queued,
            expectedUpdatedAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        ))
        #expect(try fixture.store.markMeetingAgentJobFailed(
            id: job.id, from: .queued,
            expectedUpdatedAt: Date(timeIntervalSince1970: 11),
            errorCode: "FAILED", errorMessage: "first attempt",
            updatedAt: Date(timeIntervalSince1970: 12)
        ))
        #expect(try fixture.store.transitionMeetingAgentJob(
            id: job.id, from: .failed, to: .queued,
            expectedUpdatedAt: Date(timeIntervalSince1970: 12),
            updatedAt: Date(timeIntervalSince1970: 13)
        ))
        #expect(!(try fixture.store.transitionMeetingAgentJob(
            id: job.id, from: .queued, to: .running,
            expectedUpdatedAt: Date(timeIntervalSince1970: 11),
            updatedAt: Date(timeIntervalSince1970: 11.5)
        )))
        #expect(try fixture.store.loadMeetingAgentJob(id: job.id)?.updatedAt == Date(timeIntervalSince1970: 13))
    }

    @Test("subsecond timestamps round-trip through transition CAS")
    func subsecondTransitionCAS() throws {
        let fixture = try StoreFixture("subsecond-cas")
        defer { fixture.close() }
        try fixture.insertMeeting(id: "meeting-subsecond")
        let createdAt = Date(timeIntervalSince1970: 10.123456789)
        let job = fixture.job(id: "job-subsecond", meetingID: "meeting-subsecond", createdAt: createdAt.timeIntervalSince1970)
        try fixture.store.createMeetingAgentJob(job)
        #expect(try fixture.store.transitionMeetingAgentJob(
            id: job.id, from: .submitting, to: .queued,
            expectedUpdatedAt: createdAt,
            updatedAt: Date(timeIntervalSince1970: 11.987654321)
        ))
    }

    @Test("deleting one meeting cascades only its Agent records")
    func meetingDeletionCascade() throws {
        let fixture = try StoreFixture("meeting-cascade")
        defer { fixture.close() }
        try fixture.insertMeeting(id: "meeting-delete")
        try fixture.insertMeeting(id: "meeting-keep")
        try fixture.store.createMeetingAgentJob(fixture.job(id: "job-delete", meetingID: "meeting-delete"))
        try fixture.store.createMeetingAgentJob(fixture.job(id: "job-keep", meetingID: "meeting-keep"))
        try fixture.makeImportable(jobID: "job-delete")
        try fixture.makeImportable(jobID: "job-keep")
        _ = try fixture.store.importMeetingAgentResult(
            jobID: "job-delete",
            result: fixture.result(id: "job-delete", jobID: "job-delete", meetingID: "meeting-delete"),
            todos: [fixture.todo(id: "todo-delete", jobID: "job-delete", meetingID: "meeting-delete")]
        )
        _ = try fixture.store.importMeetingAgentResult(
            jobID: "job-keep",
            result: fixture.result(id: "job-keep", jobID: "job-keep", meetingID: "meeting-keep"),
            todos: [fixture.todo(id: "todo-keep", jobID: "job-keep", meetingID: "meeting-keep")]
        )

        try fixture.store.deleteMeeting(id: "meeting-delete")

        #expect(try fixture.store.loadMeetingAgentJob(id: "job-delete") == nil)
        #expect(try fixture.store.loadMeetingAgentResult(jobID: "job-delete") == nil)
        #expect(try fixture.store.loadMeetingTodos(meetingID: "meeting-delete").isEmpty)
        #expect(try fixture.store.loadMeetingAgentJob(id: "job-keep")?.status == .ready)
        #expect(try fixture.store.loadMeetingAgentResult(jobID: "job-keep")?.id == "job-keep")
        #expect(try fixture.store.loadMeetingTodos(meetingID: "meeting-keep").map(\.todoID) == ["todo-keep"])
    }

    @Test("result, initial todos, and ready transition commit in one transaction")
    func transactionalImport() throws {
        let fixture = try StoreFixture("transactional-import")
        defer { fixture.close() }
        try fixture.insertMeeting(id: "meeting-import")
        try fixture.store.createMeetingAgentJob(fixture.job(id: "job-import", meetingID: "meeting-import"))
        try fixture.makeImportable(jobID: "job-import")
        let result = fixture.result(id: "job-import", jobID: "job-import", meetingID: "meeting-import")
        let todo = fixture.todo(id: "todo-import", jobID: "job-import", meetingID: "meeting-import")

        let imported = try fixture.store.importMeetingAgentResult(
            jobID: "job-import",
            result: result,
            todos: [todo]
        )

        #expect(imported == result)
        #expect(try fixture.store.loadMeetingAgentResult(jobID: "job-import") == result)
        #expect(try fixture.store.loadMeetingTodos(meetingID: "meeting-import") == [todo])
        let job = try #require(try fixture.store.loadMeetingAgentJob(id: "job-import"))
        #expect(job.status == .ready)
        #expect(job.completedAt == result.importedAt)
    }

    @Test("database failure rolls back import and corrected input can retry successfully")
    func importRollbackAndRetry() throws {
        let fixture = try StoreFixture("import-rollback")
        defer { fixture.close() }
        try fixture.insertMeeting(id: "meeting-rollback")
        try fixture.store.createMeetingAgentJob(
            fixture.job(id: "job-rollback", meetingID: "meeting-rollback")
        )
        try fixture.makeImportable(jobID: "job-rollback")
        try fixture.database.execute(
            """
            CREATE TRIGGER reject_todo_for_rollback_test
            BEFORE INSERT ON meeting_todos
            WHEN NEW.id = 'todo-rollback'
            BEGIN
                SELECT RAISE(ABORT, 'forced todo constraint failure');
            END;
            """
        )

        #expect(throws: (any Error).self) {
            try fixture.store.importMeetingAgentResult(
                jobID: "job-rollback",
                result: fixture.result(id: "job-rollback", jobID: "job-rollback", meetingID: "meeting-rollback"),
                todos: [fixture.todo(id: "todo-rollback", jobID: "job-rollback", meetingID: "meeting-rollback")]
            )
        }
        #expect(try fixture.store.loadMeetingAgentResult(jobID: "job-rollback") == nil)
        #expect(try fixture.store.loadMeetingTodos(meetingID: "meeting-rollback").isEmpty)
        #expect(try fixture.store.loadMeetingAgentJob(id: "job-rollback")?.status == .importing)

        try fixture.database.execute("DROP TRIGGER reject_todo_for_rollback_test;")
        let result = try fixture.store.importMeetingAgentResult(
            jobID: "job-rollback",
            result: fixture.result(id: "job-rollback", jobID: "job-rollback", meetingID: "meeting-rollback"),
            todos: [fixture.todo(id: "todo-rollback", jobID: "job-rollback", meetingID: "meeting-rollback")]
        )
        #expect(result.id == "job-rollback")
        #expect(try fixture.store.loadMeetingAgentJob(id: "job-rollback")?.status == .ready)
        #expect(try fixture.store.loadMeetingTodos(meetingID: "meeting-rollback").map(\.todoID) == ["todo-rollback"])
    }

    @Test("different jobs may persist the same stable todo id")
    func todoIDsAreScopedToJobs() throws {
        let fixture = try StoreFixture("todo-scope")
        defer { fixture.close() }
        let meetingID = "meeting-shared"
        try fixture.insertMeeting(id: meetingID)
        for suffix in ["one", "two"] {
            let jobID = "job-\(suffix)"
            try fixture.store.createMeetingAgentJob(fixture.job(id: jobID, meetingID: meetingID))
            try fixture.makeImportable(jobID: jobID)
            _ = try fixture.store.importMeetingAgentResult(
                jobID: jobID,
                result: fixture.result(id: jobID, jobID: jobID, meetingID: meetingID),
                todos: [fixture.todo(id: "stable-todo", jobID: jobID, meetingID: meetingID)]
            )
        }

        let todos = try fixture.store.loadMeetingTodos(meetingID: meetingID)
        #expect(todos.map(\.todoID) == ["stable-todo", "stable-todo"])
        #expect(Set(todos.map(\.id)) == [
            MeetingTodoIdentity(jobID: "job-one", todoID: "stable-todo"),
            MeetingTodoIdentity(jobID: "job-two", todoID: "stable-todo")
        ])
    }

    @Test("ready import retries are idempotent and preserve confirmed edits")
    func readyRetryPreservesTodos() throws {
        let fixture = try StoreFixture("ready-retry")
        defer { fixture.close() }
        try fixture.insertMeeting(id: "meeting-retry")
        try fixture.store.createMeetingAgentJob(fixture.job(id: "job-retry", meetingID: "meeting-retry"))
        try fixture.makeImportable(jobID: "job-retry")
        let result = fixture.result(id: "job-retry", jobID: "job-retry", meetingID: "meeting-retry")
        let todo = fixture.todo(id: "todo-retry", jobID: "job-retry", meetingID: "meeting-retry")
        _ = try fixture.store.importMeetingAgentResult(jobID: "job-retry", result: result, todos: [todo])
        try fixture.database.execute(
            """
            UPDATE meeting_todos
            SET detail = '人工补充内容', confirmation_status = 'confirmed', updated_at = 99
            WHERE id = 'todo-retry'
            """
        )

        var samePackage = result
        samePackage.importedAt = Date(timeIntervalSince1970: 999)
        let retry = try fixture.store.importMeetingAgentResult(
            jobID: "job-retry",
            result: samePackage,
            todos: [fixture.todo(id: "replacement", jobID: "job-retry", meetingID: "meeting-retry")]
        )

        #expect(retry == result)
        let saved = try #require(try fixture.store.loadMeetingTodos(meetingID: "meeting-retry").first)
        #expect(saved.todoID == "todo-retry")
        #expect(saved.detail == "人工补充内容")
        #expect(saved.confirmationStatus == .confirmed)
        #expect(saved.updatedAt == Date(timeIntervalSince1970: 99))
    }

    @Test("an importing retry can fill missing data, but a different result conflicts")
    func importingRetryAndResultConflict() throws {
        let fixture = try StoreFixture("import-conflict")
        defer { fixture.close() }
        try fixture.insertMeeting(id: "meeting-conflict")
        try fixture.store.createMeetingAgentJob(fixture.job(id: "job-conflict", meetingID: "meeting-conflict"))
        try fixture.makeImportable(jobID: "job-conflict")
        let result = fixture.result(id: "job-conflict", jobID: "job-conflict", meetingID: "meeting-conflict")

        _ = try fixture.store.importMeetingAgentResult(jobID: "job-conflict", result: result, todos: [])
        #expect(try fixture.store.loadMeetingAgentResult(jobID: "job-conflict") == result)

        var different = result
        different.reportRelativePath = "agent/jobs/job-conflict/other.html"
        #expect(throws: MeetingAgentRepositoryError.resultConflict) {
            try fixture.store.importMeetingAgentResult(jobID: "job-conflict", result: different, todos: [])
        }
        #expect(try fixture.store.loadMeetingAgentResult(jobID: "job-conflict") == result)
    }

    @Test("public import boundary rejects todos that are already confirmed")
    func rejectsNonPendingTodos() throws {
        let fixture = try StoreFixture("todo-status")
        defer { fixture.close() }
        try fixture.insertMeeting(id: "meeting-todo-status")
        try fixture.store.createMeetingAgentJob(
            fixture.job(id: "job-todo-status", meetingID: "meeting-todo-status")
        )
        try fixture.makeImportable(jobID: "job-todo-status")
        var todo = fixture.todo(
            id: "todo-confirmed",
            jobID: "job-todo-status",
            meetingID: "meeting-todo-status"
        )
        todo.confirmationStatus = .confirmed

        #expect(throws: MeetingAgentRepositoryError.invalidRecord) {
            try fixture.store.importMeetingAgentResult(
                jobID: "job-todo-status",
                result: fixture.result(
                    id: "job-todo-status",
                    jobID: "job-todo-status",
                    meetingID: "meeting-todo-status"
                ),
                todos: [todo]
            )
        }
        #expect(try fixture.store.loadMeetingAgentResult(jobID: "job-todo-status") == nil)
        #expect(try fixture.store.loadMeetingTodos(meetingID: "meeting-todo-status").isEmpty)
        #expect(try fixture.store.loadMeetingAgentJob(id: "job-todo-status")?.status == .importing)
    }

    @Test("import boundary rejects invalid identities, paths, hashes, todos, and evidence")
    func rejectsInvalidImportRecords() throws {
        let fixture = try StoreFixture("invalid-import")
        defer { fixture.close() }
        try fixture.insertMeeting(id: "meeting-invalid")
        try fixture.store.createMeetingAgentJob(fixture.job(id: "job-invalid", meetingID: "meeting-invalid"))
        try fixture.makeImportable(jobID: "job-invalid")
        let validResult = fixture.result(id: "job-invalid", jobID: "job-invalid", meetingID: "meeting-invalid")
        let validTodo = fixture.todo(id: "todo-valid", jobID: "job-invalid", meetingID: "meeting-invalid")

        var wrongResultID = validResult
        wrongResultID.id = "other-result"
        #expect(throws: MeetingAgentRepositoryError.identityMismatch) {
            try fixture.store.importMeetingAgentResult(jobID: "job-invalid", result: wrongResultID, todos: [validTodo])
        }

        var unsafePath = validResult
        unsafePath.reportRelativePath = "../report.html"
        #expect(throws: MeetingAgentRepositoryError.invalidRecord) {
            try fixture.store.importMeetingAgentResult(jobID: "job-invalid", result: unsafePath, todos: [validTodo])
        }

        var invalidHash = validResult
        invalidHash.manifestSHA256 = "not-a-sha"
        #expect(throws: MeetingAgentRepositoryError.invalidRecord) {
            try fixture.store.importMeetingAgentResult(jobID: "job-invalid", result: invalidHash, todos: [validTodo])
        }

        var emptyTitle = validTodo
        emptyTitle.title = "  "
        #expect(throws: MeetingAgentRepositoryError.invalidRecord) {
            try fixture.store.importMeetingAgentResult(jobID: "job-invalid", result: validResult, todos: [emptyTitle])
        }

        var noEvidence = validTodo
        noEvidence.evidence = []
        noEvidence.owner = "负责人"
        noEvidence.deadline = "2026-08-01"
        #expect(throws: MeetingAgentRepositoryError.invalidRecord) {
            try fixture.store.importMeetingAgentResult(jobID: "job-invalid", result: validResult, todos: [noEvidence])
        }

        var invalidEvidence = validTodo
        invalidEvidence.evidence = [MeetingTodoEvidence(segmentID: "", quote: "原文", timeRange: "00:00-00:01")]
        #expect(throws: MeetingAgentRepositoryError.invalidRecord) {
            try fixture.store.importMeetingAgentResult(jobID: "job-invalid", result: validResult, todos: [invalidEvidence])
        }

        var emptyOwner = validTodo
        emptyOwner.owner = "  "
        emptyOwner.evidence = []
        #expect(throws: MeetingAgentRepositoryError.invalidRecord) {
            try fixture.store.importMeetingAgentResult(jobID: "job-invalid", result: validResult, todos: [emptyOwner])
        }

        var uppercaseHash = validResult
        uppercaseHash.manifestSHA256 = uppercaseHash.manifestSHA256.uppercased()
        #expect(throws: MeetingAgentRepositoryError.invalidRecord) {
            try fixture.store.importMeetingAgentResult(jobID: "job-invalid", result: uppercaseHash, todos: [validTodo])
        }

        #expect(throws: MeetingAgentRepositoryError.invalidRecord) {
            try fixture.store.importMeetingAgentResult(
                jobID: "job-invalid",
                result: validResult,
                todos: [validTodo, validTodo]
            )
        }
        #expect(try fixture.store.loadMeetingAgentResult(jobID: "job-invalid") == nil)
        #expect(try fixture.store.loadMeetingAgentJob(id: "job-invalid")?.status == .importing)

        var unassigned = validTodo
        unassigned.todoID = "todo-unassigned"
        unassigned.owner = nil
        unassigned.deadline = nil
        unassigned.evidence = []
        _ = try fixture.store.importMeetingAgentResult(
            jobID: "job-invalid",
            result: validResult,
            todos: [unassigned]
        )
        #expect(try fixture.store.loadMeetingAgentJob(id: "job-invalid")?.status == .ready)
    }

    @Test("chat messages persist by meeting and update streaming state")
    func chatMessagePersistence() throws {
        let fixture = try StoreFixture("chat-messages")
        defer { fixture.close() }
        try fixture.insertMeeting(id: "meeting-chat")
        try fixture.insertMeeting(id: "meeting-other")

        let user = MeetingAgentChatMessage(
            id: "chat-user",
            meetingID: "meeting-chat",
            role: .user,
            content: "我的名字是什么？",
            createdAt: Date(timeIntervalSince1970: 10)
        )
        var assistant = MeetingAgentChatMessage(
            id: "chat-assistant",
            meetingID: "meeting-chat",
            role: .assistant,
            content: "",
            reasoning: "正在核对人员库",
            activity: ["已载入 17 名人员"],
            timeline: [
                MeetingAgentTurnSegment(
                    id: "process-1",
                    kind: .process,
                    reasoning: "正在核对人员库",
                    activity: ["已载入 17 名人员"]
                )
            ],
            status: .streaming,
            createdAt: Date(timeIntervalSince1970: 11)
        )
        let other = MeetingAgentChatMessage(
            id: "chat-other",
            meetingID: "meeting-other",
            role: .user,
            content: "另一场会议",
            createdAt: Date(timeIntervalSince1970: 12)
        )
        try fixture.store.upsertMeetingAgentChatMessage(user)
        try fixture.store.upsertMeetingAgentChatMessage(assistant)
        try fixture.store.upsertMeetingAgentChatMessage(other)

        assistant.content = "你是李明。"
        assistant.timeline.append(MeetingAgentTurnSegment(
            id: "final-1",
            kind: .final,
            content: "你是李明。"
        ))
        assistant.status = .completed
        assistant.updatedAt = Date(timeIntervalSince1970: 13)
        try fixture.store.upsertMeetingAgentChatMessage(assistant)

        #expect(try fixture.store.loadMeetingAgentChatMessages(meetingID: "meeting-chat") == [user, assistant])
        #expect(try fixture.store.loadSnapshot().meetingAgentMessagesByMeeting["meeting-other"] == [other])

        try fixture.store.deleteMeeting(id: "meeting-chat")
        #expect(try fixture.store.loadMeetingAgentChatMessages(meetingID: "meeting-chat").isEmpty)
    }
}

private final class StoreFixture {
    let root: URL
    let path: String
    let store: AppPersistenceStore
    let database: Database

    init(_ name: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AItingji-agent-repo-\(name)-\(UUID().uuidString)")
        path = root.appendingPathComponent("app.sqlite").path
        store = try AppPersistenceStore(path: path)
        database = try Database(path: path)
        try database.migrate()
    }

    func insertMeeting(id: String) throws {
        try store.upsertMeeting(Meeting(
            id: id,
            title: "Agent 测试会议",
            status: .done,
            createdAt: Date(timeIntervalSince1970: 1)
        ))
    }

    func job(id: String, meetingID: String, createdAt: TimeInterval = 10) -> MeetingAgentJob {
        MeetingAgentJob(
            id: id,
            meetingID: meetingID,
            requestHash: "hash-\(id)",
            provider: "mock",
            analysisGoal: "分析风险",
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    func result(id: String, jobID: String, meetingID: String) -> MeetingAgentResult {
        MeetingAgentResult(
            id: id,
            jobID: jobID,
            meetingID: meetingID,
            manifestRelativePath: "agent/jobs/\(jobID)/manifest.json",
            reportRelativePath: "agent/jobs/\(jobID)/report.html",
            manifestSHA256: String(repeating: "a", count: 64),
            importedAt: Date(timeIntervalSince1970: 30)
        )
    }

    func todo(id: String, jobID: String, meetingID: String) -> MeetingTodo {
        MeetingTodo(
            id: id,
            jobID: jobID,
            meetingID: meetingID,
            title: "形成实施方案",
            detail: "根据会议确认范围形成方案初稿",
            deliverable: "实施方案初稿",
            acceptanceCriteria: "覆盖会议确认范围",
            evidence: [
                MeetingTodoEvidence(
                    segmentID: "segment-1",
                    quote: "形成方案初稿",
                    timeRange: "00:21:10-00:21:20"
                )
            ],
            createdAt: Date(timeIntervalSince1970: 30)
        )
    }

    func makeImportable(jobID: String) throws {
        #expect(try store.transitionMeetingAgentJob(
            id: jobID,
            from: .submitting,
            to: .queued,
            expectedUpdatedAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 15)
        ))
        #expect(try store.transitionMeetingAgentJob(
            id: jobID,
            from: .queued,
            to: .importing,
            expectedUpdatedAt: Date(timeIntervalSince1970: 15),
            updatedAt: Date(timeIntervalSince1970: 20)
        ))
    }

    func close() {
        database.close()
        store.close()
        try? FileManager.default.removeItem(at: root)
    }
}
