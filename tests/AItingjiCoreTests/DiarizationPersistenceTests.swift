import AItingjiCore
import Foundation
import Testing

@Test
func meetingAudioPathAndDiarizationResultsPersistAcrossDatabaseReopen() throws {
    let path = temporaryDiarizationDatabasePath("persist")
    let database = try Database(path: path)
    try database.migrate()
    let meetings = MeetingRepository(database: database)
    try meetings.create(
        Meeting(
            id: "meeting-diarization",
            title: "说话人分离会议",
            createdAt: Date(timeIntervalSince1970: 100),
            audioFilePath: "/tmp/meeting.wav",
            microphoneAudioFilePath: "/tmp/microphone.wav",
            computerAudioFilePath: "/tmp/computer.wav",
            diarizationStatus: .final
        )
    )
    try DiarizationRunRepository(database: database).upsert(
        DiarizationRun(
            id: "run-1",
            meetingID: "meeting-diarization",
            scope: .full,
            status: .succeeded,
            audioFilePath: "/tmp/meeting.wav",
            turns: [
                DiarizationTurn(startMs: 0, endMs: 1000, speakerKey: "SPEAKER_00", confidence: 0.9),
                DiarizationTurn(startMs: 1000, endMs: 2000, speakerKey: "SPEAKER_01", confidence: 0.88)
            ],
            createdAt: Date(timeIntervalSince1970: 101)
        )
    )
    try DiarizationSpeakerMappingRepository(database: database).upsert(
        DiarizationSpeakerMapping(
            meetingID: "meeting-diarization",
            speakerKey: "SPEAKER_01",
            speakerLabel: "未知发言人 2",
            personID: "person-li",
            personName: "李四",
            confidence: 0.96,
            isManual: true
        )
    )
    database.close()

    let reopened = try Database(path: path)
    try reopened.migrate()
    let loadedMeeting = try MeetingRepository(database: reopened).get(id: "meeting-diarization")
    let runs = try DiarizationRunRepository(database: reopened).list(meetingID: "meeting-diarization")
    let mappings = try DiarizationSpeakerMappingRepository(database: reopened).list(meetingID: "meeting-diarization")

    #expect(loadedMeeting.audioFilePath == "/tmp/meeting.wav")
    #expect(loadedMeeting.microphoneAudioFilePath == "/tmp/microphone.wav")
    #expect(loadedMeeting.computerAudioFilePath == "/tmp/computer.wav")
    #expect(loadedMeeting.diarizationStatus == .final)
    #expect(runs.count == 1)
    #expect(runs[0].turns.count == 2)
    #expect(mappings.first?.personName == "李四")
    #expect(mappings.first?.isManual == true)
    reopened.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test
func diarizationSpeakerMappingRepositoryCanDeleteMeetingMappingsBeforeFinalRerun() throws {
    let path = temporaryDiarizationDatabasePath("delete-mappings")
    let database = try Database(path: path)
    try database.migrate()
    try MeetingRepository(database: database).create(
        Meeting(id: "meeting-1", title: "待清理映射会议", createdAt: Date(timeIntervalSince1970: 100))
    )
    let repository = DiarizationSpeakerMappingRepository(database: database)
    try repository.upsert(
        DiarizationSpeakerMapping(
            meetingID: "meeting-1",
            speakerKey: "SPEAKER_00",
            speakerLabel: "未知发言人 1"
        )
    )
    try repository.upsert(
        DiarizationSpeakerMapping(
            meetingID: "meeting-1",
            speakerKey: "未知发言人 1",
            speakerLabel: "未知发言人 3"
        )
    )

    try repository.deleteAll(meetingID: "meeting-1")

    #expect(try repository.list(meetingID: "meeting-1").isEmpty)
    database.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test
func legacyDiarizationMappingsGainManualFlagDuringMigration() throws {
    let path = temporaryDiarizationDatabasePath("legacy-mapping-manual")
    let database = try Database(path: path)
    try database.migrate()
    try database.execute("ALTER TABLE diarization_speaker_mappings DROP COLUMN is_manual")
    try database.migrate()
    try MeetingRepository(database: database).create(
        Meeting(id: "meeting-legacy-mapping", title: "旧映射", createdAt: Date())
    )
    let repository = DiarizationSpeakerMappingRepository(database: database)
    try repository.upsert(DiarizationSpeakerMapping(
        meetingID: "meeting-legacy-mapping",
        speakerKey: "computer:SPEAKER_00",
        speakerLabel: "王五",
        isManual: true
    ))

    #expect(try repository.list(meetingID: "meeting-legacy-mapping").first?.isManual == true)
    database.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test
func legacyMeetingsDefaultToNoDiarizationAfterMigration() throws {
    let path = temporaryDiarizationDatabasePath("legacy")
    let database = try Database(path: path)
    try database.migrate()
    try database.execute("ALTER TABLE meetings DROP COLUMN audio_file_path")
    try database.execute("ALTER TABLE meetings DROP COLUMN microphone_audio_file_path")
    try database.execute("ALTER TABLE meetings DROP COLUMN computer_audio_file_path")
    try database.execute("ALTER TABLE meetings DROP COLUMN diarization_status")
    try database.execute(
        """
        INSERT INTO meetings (
            id, title, status, capture_source, created_at,
            started_at, ended_at, model_snapshot, voiceprint_snapshot, is_archived
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            .text("{}"),
            .integer(0)
        ]
    )

    try database.migrate()
    let meeting = try MeetingRepository(database: database).get(id: "legacy")

    #expect(meeting.audioFilePath == nil)
    #expect(meeting.microphoneAudioFilePath == nil)
    #expect(meeting.computerAudioFilePath == nil)
    #expect(meeting.diarizationStatus == .notStarted)
    database.close()
    try? FileManager.default.removeItem(atPath: path)
}

private func temporaryDiarizationDatabasePath(_ name: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("AItingji-\(UUID().uuidString)-\(name)")
        .appendingPathExtension("sqlite")
        .path
}
