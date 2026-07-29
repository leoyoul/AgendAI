import Foundation
import Testing
@testable import AItingjiCore

@Test func repositoriesPersistMutationsAcrossDatabaseReopen() throws {
    let path = temporaryDatabasePath()
    let apiKeyStore = InMemoryModelSourceAPIKeyStore()

    do {
        let database = try Database(path: path)
        try database.migrate()
        let meetings = MeetingRepository(database: database)
        let segments = SegmentRepository(database: database)
        let people = PeopleRepository(database: database)
        let models = ModelSourceRepository(database: database, apiKeyStore: apiKeyStore)

        let meeting = Meeting(
            id: "meeting-mutation",
            title: "持久化会议",
            status: .draft,
            captureSource: .microphone,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try meetings.upsert(meeting)

        var updatedMeeting = meeting
        updatedMeeting.status = .recording
        updatedMeeting.captureSource = .mixed
        updatedMeeting.startedAt = Date(timeIntervalSince1970: 1_800_000_100)
        updatedMeeting.recordingIntervals = [
            MeetingRecordingInterval(
                id: "interval-mutation",
                startedAt: Date(timeIntervalSince1970: 1_800_000_100),
                endedAt: Date(timeIntervalSince1970: 1_800_000_160)
            )
        ]
        try meetings.upsert(updatedMeeting)

        var segment = TranscriptSegment(
            id: "segment-mutation",
            meetingID: meeting.id,
            startMs: 0,
            endMs: 4_000,
            speakerLabel: "未知发言人 1",
            autoSpeakerLabel: "未知发言人 1",
            confidence: 0.42,
            rawText: "原始文本"
        )
        try segments.upsert(segment)

        segment.finalText = "人工修正后的文本"
        segment.speakerLabel = "王五"
        segment.personName = "王五"
        segment.isManual = true
        segment.manualReason = "人工改名"
        try segments.upsert(segment)

        try people.upsert(
            VoiceprintPerson(
                id: "person-wang",
                displayName: "王五",
                aliases: ["小王"],
                threshold: 0.86
            )
        )

        try models.upsert(
            ModelSource(
                id: "model-asr",
                type: .asr,
                name: "转写服务",
                baseURL: "https://api.example.com/v1",
                apiKey: "sk-test",
                selectedModel: "whisper-large-v3",
                isDefault: true
            )
        )
        database.close()
    }

    do {
        let database = try Database(path: path)
        try database.migrate()
        let meetings = MeetingRepository(database: database)
        let segments = SegmentRepository(database: database)
        let people = PeopleRepository(database: database)
        let models = ModelSourceRepository(database: database, apiKeyStore: apiKeyStore)

        let meeting = try meetings.get(id: "meeting-mutation")
        #expect(meeting.status == .recording)
        #expect(meeting.captureSource == .mixed)
        #expect(meeting.startedAt != nil)
        #expect(meeting.recordingIntervals.count == 1)
        #expect(meeting.recordingIntervals[0].id == "interval-mutation")

        let savedSegments = try segments.list(meetingID: "meeting-mutation")
        #expect(savedSegments.count == 1)
        #expect(savedSegments[0].finalText == "人工修正后的文本")
        #expect(savedSegments[0].personName == "王五")
        #expect(savedSegments[0].isManual)

        let savedPeople = try people.list()
        #expect(savedPeople.map(\.displayName) == ["王五"])
        #expect(savedPeople[0].aliases == ["小王"])

        let savedModels = try models.list()
        #expect(savedModels.count == 1)
        #expect(savedModels[0].selectedModel == "whisper-large-v3")
        #expect(savedModels[0].isDefault)
        database.close()
    }

    try? FileManager.default.removeItem(atPath: path)
}

@Test func meetingRepositoryReadsLegacyISO8601Dates() throws {
    let path = temporaryDatabasePath()
    let database = try Database(path: path)
    try database.migrate()
    try database.execute(
        """
        INSERT INTO meetings (
            id, title, status, capture_source, created_at,
            started_at, ended_at, model_snapshot, voiceprint_snapshot
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
            .text("legacy-meeting"),
            .text("旧库会议"),
            .text("draft"),
            .text("microphone"),
            .text("2026-06-26T09:39:30.861928+00:00"),
            .text("2026-06-26T09:40:30+00:00"),
            .null,
            .text("{}"),
            .text("{}")
        ]
    )

    let meeting = try MeetingRepository(database: database).get(id: "legacy-meeting")
    #expect(Calendar.current.component(.year, from: meeting.createdAt) == 2026)
    #expect(meeting.startedAt != nil)
    if let startedAt = meeting.startedAt {
        #expect(Calendar.current.component(.minute, from: startedAt) == 40)
    }
    database.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func readyForHandoffAndContentMutationFollowHandoffStateMachine() throws {
    let path = temporaryDatabasePath()
    let database = try Database(path: path)
    try database.migrate()
    let meetings = MeetingRepository(database: database)
    let segments = SegmentRepository(database: database)
    var meeting = Meeting(
        id: "meeting-handoff-state",
        title: "交接状态",
        status: .processing,
        createdAt: Date()
    )
    try meetings.upsert(meeting)
    try segments.upsert(TranscriptSegment(
        id: "segment-handoff-state",
        meetingID: meeting.id,
        startMs: 0,
        endMs: 1_000,
        speakerLabel: "发言人",
        rawText: "原文"
    ))

    meeting.status = .done
    try meetings.persistReadyForHandoff(meeting)
    var loaded = try meetings.get(id: meeting.id)
    #expect(loaded.status == .done)
    #expect(loaded.handoffStatus == .pending)
    #expect(loaded.handoffError == nil)

    try database.execute(
        """
        UPDATE meetings
        SET handoff_status = 'processing',
            handoff_started_at = 100,
            handoff_completed_at = 200,
            handoff_content_hash = 'old-hash',
            handoff_error = 'old-error'
        WHERE id = ?
        """,
        bindings: [.text(meeting.id)]
    )
    var segment = try segments.list(meetingID: meeting.id)[0]
    segment.finalText = "修改后的正文"
    #expect(throws: MeetingRepositoryError.contentLockedByHandoff) {
        try segments.upsert(segment)
    }

    loaded = try meetings.get(id: meeting.id)
    #expect(loaded.handoffStatus == .processing)
    #expect(loaded.handoffStartedAt == Date(timeIntervalSince1970: 100))
    #expect(loaded.handoffCompletedAt == Date(timeIntervalSince1970: 200))
    #expect(loaded.handoffContentHash == "old-hash")
    #expect(loaded.handoffError == "old-error")
    #expect(try segments.list(meetingID: meeting.id).first?.finalText.isEmpty == true)

    try database.execute(
        """
        UPDATE meetings
        SET handoff_status = 'completed', handoff_completed_at = 300,
            handoff_content_hash = 'title-hash'
        WHERE id = ?
        """,
        bindings: [.text(meeting.id)]
    )
    #expect(throws: MeetingRepositoryError.contentLockedByHandoff) {
        try meetings.updateTitle(id: meeting.id, title: "交接状态（修订）")
    }
    loaded = try meetings.get(id: meeting.id)
    #expect(loaded.handoffStatus == .completed)
    #expect(loaded.handoffCompletedAt == Date(timeIntervalSince1970: 300))
    #expect(loaded.handoffContentHash == "title-hash")

    database.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func restoreUsesCASAndReadyWriteCannotOverwriteExternalCompletion() throws {
    let path = temporaryDatabasePath()
    let appDatabase = try Database(path: path)
    try appDatabase.migrate()
    let repository = MeetingRepository(database: appDatabase)
    var staleMeeting = Meeting(
        id: "meeting-handoff-race",
        title: "竞态会议",
        status: .processing,
        createdAt: Date()
    )
    try repository.upsert(staleMeeting)

    let externalDatabase = try Database(path: path)
    try externalDatabase.migrate()
    try externalDatabase.execute(
        """
        UPDATE meetings
        SET status = 'done', handoff_status = 'completed', is_archived = 1,
            handoff_completed_at = 300, handoff_content_hash = 'completed-hash'
        WHERE id = ?
        """,
        bindings: [.text(staleMeeting.id)]
    )

    staleMeeting.status = .done
    try repository.persistReadyForHandoff(staleMeeting)
    var loaded = try repository.get(id: staleMeeting.id)
    #expect(loaded.handoffStatus == .completed)
    #expect(loaded.isArchived)
    #expect(loaded.handoffContentHash == "completed-hash")

    try repository.setArchived(
        id: staleMeeting.id,
        isArchived: false,
        restoredHandoffStatus: .pending
    )
    loaded = try repository.get(id: staleMeeting.id)
    #expect(!loaded.isArchived)
    #expect(loaded.handoffStatus == .pending)
    #expect(loaded.handoffCompletedAt == nil)
    #expect(loaded.handoffContentHash == nil)

    try externalDatabase.execute(
        """
        UPDATE meetings
        SET handoff_status = 'processing', is_archived = 1
        WHERE id = ?
        """,
        bindings: [.text(staleMeeting.id)]
    )
    try repository.setArchived(
        id: staleMeeting.id,
        isArchived: false,
        restoredHandoffStatus: .pending
    )
    loaded = try repository.get(id: staleMeeting.id)
    #expect(loaded.isArchived)
    #expect(loaded.handoffStatus == .processing)

    externalDatabase.close()
    appDatabase.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func staleContentWritesAreRejectedAfterHandoffOwnsMeeting() throws {
    let path = temporaryDatabasePath()
    let appDatabase = try Database(path: path)
    try appDatabase.migrate()
    let meetings = MeetingRepository(database: appDatabase)
    let segments = SegmentRepository(database: appDatabase)
    var staleMeeting = Meeting(
        id: "meeting-content-lock",
        title: "锁定前标题",
        status: .done,
        createdAt: Date()
    )
    try meetings.upsert(staleMeeting)
    let originalSegment = TranscriptSegment(
        id: "segment-content-lock",
        meetingID: staleMeeting.id,
        startMs: 0,
        endMs: 1_000,
        speakerLabel: "发言人",
        rawText: "锁定前原文",
        finalText: "锁定前正文"
    )
    try segments.upsert(originalSegment)

    let externalDatabase = try Database(path: path)
    try externalDatabase.migrate()
    try externalDatabase.execute(
        """
        UPDATE meetings
        SET handoff_status = 'completed', is_archived = 1,
            handoff_completed_at = 300, handoff_content_hash = 'completed-hash'
        WHERE id = ?
        """,
        bindings: [.text(staleMeeting.id)]
    )

    staleMeeting.title = "陈旧标题不应写入"
    try? meetings.upsert(staleMeeting)
    var modifiedSegment = originalSegment
    modifiedSegment.finalText = "陈旧正文不应写入"
    try? segments.upsert(modifiedSegment)
    try? segments.create(TranscriptSegment(
        id: "segment-content-lock-new",
        meetingID: staleMeeting.id,
        startMs: 2_000,
        endMs: 3_000,
        speakerLabel: "发言人",
        rawText: "陈旧新增"
    ))
    try? segments.delete(id: originalSegment.id)
    try? segments.deleteAll(meetingID: staleMeeting.id)

    var loadedMeeting = try meetings.get(id: staleMeeting.id)
    var loadedSegments = try segments.list(meetingID: staleMeeting.id)
    #expect(loadedMeeting.title == "锁定前标题")
    #expect(loadedMeeting.handoffStatus == .completed)
    #expect(loadedMeeting.isArchived)
    #expect(loadedSegments == [originalSegment])

    try externalDatabase.execute(
        """
        UPDATE meetings
        SET handoff_status = 'processing', is_archived = 0,
            handoff_completed_at = NULL, handoff_content_hash = 'processing-hash'
        WHERE id = ?
        """,
        bindings: [.text(staleMeeting.id)]
    )
    staleMeeting.title = "交接中陈旧标题"
    try? meetings.upsert(staleMeeting)
    modifiedSegment.finalText = "交接中陈旧正文"
    try? segments.upsert(modifiedSegment)

    loadedMeeting = try meetings.get(id: staleMeeting.id)
    loadedSegments = try segments.list(meetingID: staleMeeting.id)
    #expect(loadedMeeting.title == "锁定前标题")
    #expect(loadedMeeting.handoffStatus == .processing)
    #expect(loadedSegments == [originalSegment])

    externalDatabase.close()
    appDatabase.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func reviewReadyMeetingRejectsContentWritesUntilConfirmation() throws {
    let path = temporaryDatabasePath()
    let database = try Database(path: path)
    try database.migrate()
    let meetings = MeetingRepository(database: database)
    let segments = SegmentRepository(database: database)
    var meeting = Meeting(
        id: "meeting-review-ready",
        title: "待人工确认会议",
        status: .done,
        createdAt: Date()
    )
    try meetings.upsert(meeting)
    let originalSegment = TranscriptSegment(
        id: "segment-review-ready",
        meetingID: meeting.id,
        startMs: 0,
        endMs: 1_000,
        speakerLabel: "发言人",
        rawText: "待确认原文"
    )
    try segments.create(originalSegment)
    try database.execute(
        """
        UPDATE meetings
        SET handoff_status = 'completed', handoff_completed_at = 300,
            handoff_content_hash = 'review-hash'
        WHERE id = ?
        """,
        bindings: [.text(meeting.id)]
    )

    meeting.title = "不应覆盖的陈旧标题"
    #expect(throws: MeetingRepositoryError.contentLockedByHandoff) {
        try meetings.upsert(meeting)
    }
    #expect(throws: MeetingRepositoryError.contentLockedByHandoff) {
        try meetings.updateTitle(id: meeting.id, title: "不应覆盖的标题")
    }
    var modifiedSegment = originalSegment
    modifiedSegment.finalText = "不应覆盖的正文"
    #expect(throws: MeetingRepositoryError.contentLockedByHandoff) {
        try segments.upsert(modifiedSegment)
    }
    #expect(throws: MeetingRepositoryError.contentLockedByHandoff) {
        try segments.create(TranscriptSegment(
            id: "segment-review-ready-new",
            meetingID: meeting.id,
            startMs: 2_000,
            endMs: 3_000,
            speakerLabel: "发言人",
            rawText: "不应新增的正文"
        ))
    }
    #expect(throws: MeetingRepositoryError.contentLockedByHandoff) {
        try segments.delete(id: originalSegment.id)
    }
    #expect(throws: MeetingRepositoryError.contentLockedByHandoff) {
        try segments.deleteAll(meetingID: meeting.id)
    }
    #expect(try meetings.get(id: meeting.id).title == "待人工确认会议")
    #expect(try segments.list(meetingID: meeting.id) == [originalSegment])

    database.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func appPostprocessContentRemainsWritableBeforeHandoffBegins() throws {
    let path = temporaryDatabasePath()
    let database = try Database(path: path)
    try database.migrate()
    let meetings = MeetingRepository(database: database)
    let segments = SegmentRepository(database: database)
    var meeting = Meeting(
        id: "meeting-postprocess-writable",
        title: "后处理前",
        status: .processing,
        createdAt: Date()
    )
    try meetings.upsert(meeting)
    var segment = TranscriptSegment(
        id: "segment-postprocess-writable",
        meetingID: meeting.id,
        startMs: 0,
        endMs: 1_000,
        speakerLabel: "发言人",
        rawText: "嗯后处理前"
    )
    try segments.upsert(segment)

    meeting.title = "后处理后"
    segment.finalText = "后处理后"
    try meetings.upsert(meeting)
    try segments.upsert(segment)

    #expect(try meetings.get(id: meeting.id).title == "后处理后")
    #expect(try segments.list(meetingID: meeting.id).first?.finalText == "后处理后")
    database.close()
    try? FileManager.default.removeItem(atPath: path)
}

private func temporaryDatabasePath() -> String {
    let directory = FileManager.default.temporaryDirectory
    return directory
        .appendingPathComponent("ai-tingji-\(UUID().uuidString).sqlite")
        .path
}
