import AItingjiCore
import Foundation
import Testing

@Suite("Meeting Agent database migration")
struct MeetingAgentDatabaseTests {
    @Test("migration creates the Agent tables with the designed columns")
    func createsAgentTablesAndColumns() throws {
        let fixture = try DatabaseFixture("agent-schema")
        defer { fixture.close() }

        let expectedColumns: [String: Set<String>] = [
            "meeting_agent_jobs": [
                "id", "meeting_id", "request_hash", "provider", "status", "analysis_goal",
                "result_relative_path", "error_code", "error_message", "created_at", "updated_at",
                "completed_at"
            ],
            "meeting_agent_results": [
                "id", "job_id", "meeting_id", "manifest_relative_path", "report_relative_path",
                "manifest_sha256", "imported_at"
            ],
            "meeting_todos": [
                "id", "job_id", "meeting_id", "title", "detail", "owner", "deadline", "deliverable",
                "acceptance_criteria", "evidence_json", "confirmation_status", "proposed_workflow",
                "created_at", "updated_at"
            ],
            "meeting_agent_chat_messages": [
                "id", "meeting_id", "role", "content", "reasoning", "activity_json", "timeline_json", "status",
                "created_at", "updated_at"
            ]
        ]

        for (table, columns) in expectedColumns {
            let rows = try fixture.database.query("PRAGMA table_info(\(table));")
            #expect(Set(rows.compactMap { $0["name"]?.stringValue }) == columns)
        }
        let todoColumns = try fixture.database.query("PRAGMA table_info(meeting_todos);")
        let primaryKeyOrder: [String: Int] = Dictionary(uniqueKeysWithValues: todoColumns.compactMap { row in
            guard let name = row["name"]?.stringValue, let order = row["pk"]?.intValue, order > 0 else {
                return nil
            }
            return (name, order)
        })
        #expect(primaryKeyOrder == ["job_id": 1, "id": 2])
    }

    @Test("Agent child rows cascade when their job or meeting is deleted")
    func createsCascadeForeignKeys() throws {
        let fixture = try DatabaseFixture("agent-foreign-keys")
        defer { fixture.close() }

        for table in [
            "meeting_agent_jobs", "meeting_agent_results", "meeting_todos", "meeting_agent_chat_messages"
        ] {
            let rows = try fixture.database.query("PRAGMA foreign_key_list(\(table));")
            #expect(!rows.isEmpty)
            #expect(rows.allSatisfy { $0["on_delete"]?.stringValue == "CASCADE" })
        }
    }

    @Test("migration preserves designed defaults and remains idempotent")
    func defaultsAndIdempotency() throws {
        let fixture = try DatabaseFixture("agent-defaults")
        defer { fixture.close() }
        try fixture.database.migrate()
        try fixture.database.migrate()
        try fixture.insertMeeting(id: "meeting-defaults")
        try fixture.database.execute(
            """
            INSERT INTO meeting_agent_jobs (
                id, meeting_id, request_hash, provider, status, created_at, updated_at
            ) VALUES ('job-defaults', 'meeting-defaults', 'hash', 'mock', 'submitting', 1, 1);
            INSERT INTO meeting_todos (
                id, job_id, meeting_id, title, created_at, updated_at
            ) VALUES ('todo-defaults', 'job-defaults', 'meeting-defaults', '待确认事项', 1, 1);
            """
        )

        let job = try #require(
            fixture.database.query("SELECT analysis_goal FROM meeting_agent_jobs WHERE id = 'job-defaults'").first
        )
        #expect(job["analysis_goal"]?.stringValue == "")

        let todo = try #require(
            fixture.database.query(
                """
                SELECT detail, evidence_json, confirmation_status, proposed_workflow
                FROM meeting_todos WHERE id = 'todo-defaults'
                """
            ).first
        )
        #expect(todo["detail"]?.stringValue == "")
        #expect(todo["evidence_json"]?.stringValue == "[]")
        #expect(todo["confirmation_status"]?.stringValue == "pending_confirmation")
        #expect(todo["proposed_workflow"]?.stringValue == "none")
    }

    @Test("Agent domain raw values are stable and jobs default to submitting")
    func domainDefaults() {
        #expect(MeetingAgentJobStatus.allCases.map(\.rawValue) == [
            "submitting", "queued", "running", "importing", "ready", "failed", "cancelled"
        ])
        #expect(MeetingTodoConfirmationStatus.allCases.map(\.rawValue) == [
            "pending_confirmation", "confirmed", "ignored"
        ])
        #expect(MeetingTodoWorkflow.allCases.map(\.rawValue) == ["none", "zentao"])

        let job = MeetingAgentJob(
            id: "job-default-status",
            meetingID: "meeting-default-status",
            requestHash: "hash",
            provider: "mock",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        #expect(job.status == .submitting)
        #expect(job.updatedAt == job.createdAt)
    }

    @Test("migration upgrades the legacy global todo primary key")
    func upgradesLegacyTodoPrimaryKey() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("AItingji-agent-legacy-todos-\(UUID().uuidString).sqlite")
            .path
        let database = try Database(path: path)
        defer {
            database.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        try database.execute(
            """
            CREATE TABLE meeting_todos (
                id TEXT PRIMARY KEY,
                job_id TEXT NOT NULL,
                meeting_id TEXT NOT NULL,
                title TEXT NOT NULL,
                detail TEXT NOT NULL DEFAULT '',
                owner TEXT,
                deadline TEXT,
                deliverable TEXT,
                acceptance_criteria TEXT,
                evidence_json TEXT NOT NULL DEFAULT '[]',
                confirmation_status TEXT NOT NULL DEFAULT 'pending_confirmation',
                proposed_workflow TEXT NOT NULL DEFAULT 'none',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            """
        )

        try database.migrate()

        let columns = try database.query("PRAGMA table_info(meeting_todos);")
        let primaryKeyOrder: [String: Int] = Dictionary(uniqueKeysWithValues: columns.compactMap { row in
            guard let name = row["name"]?.stringValue, let order = row["pk"]?.intValue, order > 0 else {
                return nil
            }
            return (name, order)
        })
        #expect(primaryKeyOrder == ["job_id": 1, "id": 2])
    }
}

private final class DatabaseFixture {
    let path: String
    let database: Database

    init(_ name: String) throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("AItingji-\(name)-\(UUID().uuidString).sqlite")
            .path
        database = try Database(path: path)
        try database.migrate()
    }

    func insertMeeting(id: String) throws {
        try database.execute(
            """
            INSERT INTO meetings (id, title, status, capture_source, created_at)
            VALUES (?, 'Agent 测试会议', 'done', 'mixed', 1)
            """,
            bindings: [.text(id)]
        )
    }

    func close() {
        database.close()
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }
}
