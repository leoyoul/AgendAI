import Foundation
import Testing
@testable import AItingjiCore

@Suite("Meeting handoff decommission")
struct HandoffMigrationTests {
    @Test("handoff model remains readable for legacy databases but defaults to ignored")
    func handoffModelDefaults() {
        let meeting = Meeting(
            id: "meeting-defaults",
            title: "默认会议",
            createdAt: Date()
        )

        #expect(meeting.handoffStatus == .ignored)
        #expect(meeting.handoffStartedAt == nil)
        #expect(meeting.handoffCompletedAt == nil)
        #expect(meeting.handoffContentHash == nil)
        #expect(meeting.handoffError == nil)
    }

    @Test("migration clears legacy handoff state and removes requeue triggers")
    func migrationDecommissionsHandoffWorkflow() throws {
        let path = temporaryHandoffDatabasePath("decommission")
        let database = try Database(path: path)
        defer {
            database.close()
            try? FileManager.default.removeItem(atPath: path)
        }
        try createLegacyMeetingTable(in: database)
        try insertLegacyMeeting(in: database)

        try database.migrate()
        try database.execute(
            """
            UPDATE meetings
            SET handoff_status = 'completed',
                handoff_started_at = 100,
                handoff_completed_at = 200,
                handoff_content_hash = 'legacy-hash',
                handoff_error = 'legacy-error'
            WHERE id = 'legacy-meeting';

            CREATE TRIGGER trg_meetings_handoff_title_changed
            AFTER UPDATE OF title ON meetings
            BEGIN
                UPDATE meetings SET handoff_status = 'pending' WHERE id = NEW.id;
            END;
            """
        )

        try database.migrate()

        let meeting = try MeetingRepository(database: database).get(id: "legacy-meeting")
        #expect(meeting.handoffStatus == .ignored)
        #expect(meeting.handoffStartedAt == nil)
        #expect(meeting.handoffCompletedAt == nil)
        #expect(meeting.handoffContentHash == nil)
        #expect(meeting.handoffError == nil)
        let triggers = try database.query(
            "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE '%handoff%'"
        )
        #expect(triggers.isEmpty)
        let indexes = try database.query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_meetings_handoff_pending'"
        )
        #expect(indexes.isEmpty)
    }
}

private func createLegacyMeetingTable(in database: Database) throws {
    try database.execute(
        """
        CREATE TABLE meetings (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            status TEXT NOT NULL,
            capture_source TEXT NOT NULL DEFAULT 'microphone',
            created_at REAL NOT NULL,
            started_at REAL,
            ended_at REAL,
            recording_intervals TEXT NOT NULL DEFAULT '[]',
            model_snapshot TEXT NOT NULL DEFAULT '{}',
            voiceprint_snapshot TEXT NOT NULL DEFAULT '{}',
            is_archived INTEGER NOT NULL DEFAULT 0,
            audio_file_path TEXT,
            microphone_audio_file_path TEXT,
            computer_audio_file_path TEXT,
            diarization_status TEXT NOT NULL DEFAULT 'not_started',
            error_message TEXT
        );
        """
    )
}

private func insertLegacyMeeting(in database: Database) throws {
    try database.execute(
        """
        INSERT INTO meetings (id, title, status, capture_source, created_at, is_archived)
        VALUES ('legacy-meeting', '旧会议', 'done', 'microphone', ?, 0)
        """,
        bindings: [.real(Date().timeIntervalSince1970)]
    )
}

private func temporaryHandoffDatabasePath(_ name: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("AItingji-handoff-\(name)-\(UUID().uuidString).sqlite")
        .path
}
