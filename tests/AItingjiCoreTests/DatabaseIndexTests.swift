import AItingjiCore
import Foundation
import Testing

@Test
func databaseCreatesHotPathIndexesAfterMigrate() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AItingji-idx-\(UUID().uuidString).sqlite")
        .path
    let db = try Database(path: path)
    try db.migrate()
    defer {
        db.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    let rows = try db.query("SELECT name FROM sqlite_master WHERE type = 'index';")
    let names = Set(rows.compactMap { $0["name"]?.stringValue })

    let expected: Set<String> = [
        "idx_segments_meeting_start",
        "idx_runs_meeting",
        "idx_mappings_meeting_key",
        "idx_samples_person",
        "idx_manual_overrides_segment",
        "idx_meetings_archived_created",
        "idx_unknown_speakers_meeting",
        "idx_terminology_canonical",
        "idx_agent_jobs_meeting_created",
        "idx_agent_jobs_status_updated",
        "idx_agent_results_meeting_imported",
        "idx_meeting_todos_meeting_status",
        "idx_meeting_todos_job",
        "idx_agent_chat_meeting_created",
        "idx_meeting_notes_meeting_created",
        "idx_meeting_note_images_note_created"
    ]
    for name in expected {
        #expect(names.contains(name), "missing expected index: \(name)")
    }
}

@Test
func databaseMigrateIsIdempotentForIndexes() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("AItingji-idx-idem-\(UUID().uuidString).sqlite")
        .path
    let db = try Database(path: path)
    try db.migrate()
    try db.migrate()
    try db.migrate()
    defer {
        db.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    let rows = try db.query("SELECT COUNT(*) AS c FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%';")
    #expect(rows.first?["c"]?.intValue == 16)
}
