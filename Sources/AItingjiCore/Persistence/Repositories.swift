import Foundation

public enum MeetingRepositoryError: Error, Equatable, Sendable {
    case emptyTitle
    case contentLockedByHandoff
}

public struct MeetingRepository: Sendable {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: Database) {
        self.database = database
    }

    public func create(_ meeting: Meeting) throws {
        try database.execute(
            """
            INSERT INTO meetings (
                id, title, status, capture_source, created_at,
                started_at, ended_at, recording_intervals, model_snapshot, voiceprint_snapshot, is_archived,
                handoff_status, handoff_started_at, handoff_completed_at, handoff_content_hash, handoff_error,
                audio_file_path, microphone_audio_file_path, computer_audio_file_path, diarization_status, error_message
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(meeting.id),
                .text(meeting.title),
                .text(meeting.status.rawValue),
                .text(meeting.captureSource.rawValue),
                .real(meeting.createdAt.timeIntervalSince1970),
                meeting.startedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                meeting.endedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .text(try encodeRecordingIntervals(meeting.recordingIntervals)),
                .text(try encodeDictionary(meeting.modelSnapshot)),
                .text(try encodeDictionary(meeting.voiceprintSnapshot)),
                .integer(meeting.isArchived ? 1 : 0),
                .text(meeting.handoffStatus.rawValue),
                meeting.handoffStartedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                meeting.handoffCompletedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                meeting.handoffContentHash.map(SQLiteValue.text) ?? .null,
                meeting.handoffError.map(SQLiteValue.text) ?? .null,
                meeting.audioFilePath.map(SQLiteValue.text) ?? .null,
                meeting.microphoneAudioFilePath.map(SQLiteValue.text) ?? .null,
                meeting.computerAudioFilePath.map(SQLiteValue.text) ?? .null,
                .text(meeting.diarizationStatus.rawValue),
                meeting.minutesGenerationError.map(SQLiteValue.text) ?? .null
            ]
        )
    }

    public func upsert(_ meeting: Meeting) throws {
        let changes = try database.executeReturningChanges(
            """
            INSERT INTO meetings (
                id, title, status, capture_source, created_at,
                started_at, ended_at, recording_intervals, model_snapshot, voiceprint_snapshot, is_archived,
                handoff_status, handoff_started_at, handoff_completed_at, handoff_content_hash, handoff_error,
                audio_file_path, microphone_audio_file_path, computer_audio_file_path, diarization_status, error_message
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                status = excluded.status,
                capture_source = excluded.capture_source,
                created_at = excluded.created_at,
                started_at = excluded.started_at,
                ended_at = excluded.ended_at,
                recording_intervals = excluded.recording_intervals,
                model_snapshot = excluded.model_snapshot,
                voiceprint_snapshot = excluded.voiceprint_snapshot,
                audio_file_path = excluded.audio_file_path,
                microphone_audio_file_path = excluded.microphone_audio_file_path,
                computer_audio_file_path = excluded.computer_audio_file_path,
                diarization_status = excluded.diarization_status,
                error_message = excluded.error_message
            WHERE meetings.handoff_status <> 'processing'
              AND meetings.handoff_status <> 'completed'
            """,
            bindings: [
                .text(meeting.id),
                .text(meeting.title),
                .text(meeting.status.rawValue),
                .text(meeting.captureSource.rawValue),
                .real(meeting.createdAt.timeIntervalSince1970),
                meeting.startedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                meeting.endedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .text(try encodeRecordingIntervals(meeting.recordingIntervals)),
                .text(try encodeDictionary(meeting.modelSnapshot)),
                .text(try encodeDictionary(meeting.voiceprintSnapshot)),
                .integer(meeting.isArchived ? 1 : 0),
                .text(meeting.handoffStatus.rawValue),
                meeting.handoffStartedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                meeting.handoffCompletedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                meeting.handoffContentHash.map(SQLiteValue.text) ?? .null,
                meeting.handoffError.map(SQLiteValue.text) ?? .null,
                meeting.audioFilePath.map(SQLiteValue.text) ?? .null,
                meeting.microphoneAudioFilePath.map(SQLiteValue.text) ?? .null,
                meeting.computerAudioFilePath.map(SQLiteValue.text) ?? .null,
                .text(meeting.diarizationStatus.rawValue),
                meeting.minutesGenerationError.map(SQLiteValue.text) ?? .null
            ]
        )
        guard changes > 0 else {
            throw MeetingRepositoryError.contentLockedByHandoff
        }
    }

    public func list() throws -> [Meeting] {
        let rows = try database.query("SELECT * FROM meetings ORDER BY created_at DESC")
        return try rows.map(decodeMeeting)
    }

    public func list(isArchived: Bool, limit: Int, offset: Int) throws -> [Meeting] {
        let rows = try database.query(
            """
            SELECT * FROM meetings
            WHERE is_archived = ?
            ORDER BY created_at DESC
            LIMIT ? OFFSET ?
            """,
            bindings: [
                .integer(isArchived ? 1 : 0),
                .integer(Int64(max(0, limit))),
                .integer(Int64(max(0, offset)))
            ]
        )
        return try rows.map(decodeMeeting)
    }

    public func get(id: String) throws -> Meeting {
        let rows = try database.query("SELECT * FROM meetings WHERE id = ?", bindings: [.text(id)])
        guard let row = rows.first else {
            throw DatabaseError.missingRow
        }
        return try decodeMeeting(row)
    }

    public func updateTitle(id: String, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MeetingRepositoryError.emptyTitle
        }
        let changes = try database.executeReturningChanges(
            """
            UPDATE meetings
            SET title = ?
            WHERE id = ?
              AND handoff_status <> 'processing'
              AND handoff_status <> 'completed'
            """,
            bindings: [.text(trimmed), .text(id)]
        )
        guard changes > 0 else {
            throw MeetingRepositoryError.contentLockedByHandoff
        }
    }

    /// 会议纪要生成完成后的标题写入。CAS 条件避免覆盖用户在生成期间手动修改的标题。
    public func updateGeneratedTitle(
        id: String,
        expectedTitle: String,
        title: String
    ) throws -> Meeting? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MeetingRepositoryError.emptyTitle
        }
        let changes = try database.executeReturningChanges(
            """
            UPDATE meetings
            SET title = ?,
                handoff_status = 'ignored',
                handoff_started_at = NULL,
                handoff_completed_at = NULL,
                handoff_content_hash = NULL,
                handoff_error = NULL
            WHERE id = ?
              AND title = ?
              AND status = 'done'
              AND is_archived = 0
            """,
            bindings: [.text(trimmed), .text(id), .text(expectedTitle)]
        )
        guard changes > 0 else {
            return nil
        }
        return try get(id: id)
    }

    public func setArchived(
        id: String,
        isArchived: Bool,
        restoredHandoffStatus: MeetingHandoffStatus? = nil
    ) throws {
        if !isArchived, let restoredHandoffStatus {
            try database.execute(
                """
                UPDATE meetings
                SET is_archived = 0,
                    handoff_status = ?,
                    handoff_started_at = NULL,
                    handoff_completed_at = NULL,
                    handoff_content_hash = NULL,
                    handoff_error = NULL
                WHERE id = ?
                  AND is_archived = 1
                  AND handoff_status = 'completed'
                """,
                bindings: [.text(restoredHandoffStatus.rawValue), .text(id)]
            )
            return
        }
        try database.execute(
            "UPDATE meetings SET is_archived = ? WHERE id = ?",
            bindings: [.integer(isArchived ? 1 : 0), .text(id)]
        )
    }

    @discardableResult
    public func persistReadyForHandoff(_ meeting: Meeting) throws -> Meeting {
        try database.transaction {
            try database.execute(
                """
                INSERT INTO meetings (
                    id, title, status, capture_source, created_at,
                    started_at, ended_at, recording_intervals, model_snapshot, voiceprint_snapshot, is_archived,
                    handoff_status, handoff_started_at, handoff_completed_at, handoff_content_hash, handoff_error,
                    audio_file_path, microphone_audio_file_path, computer_audio_file_path, diarization_status
                )
                VALUES (?, ?, 'done', ?, ?, ?, ?, ?, ?, ?, 0, 'pending', NULL, NULL, NULL, NULL, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    status = 'done',
                    capture_source = excluded.capture_source,
                    created_at = excluded.created_at,
                    started_at = excluded.started_at,
                    ended_at = excluded.ended_at,
                    recording_intervals = excluded.recording_intervals,
                    model_snapshot = excluded.model_snapshot,
                    voiceprint_snapshot = excluded.voiceprint_snapshot,
                    audio_file_path = excluded.audio_file_path,
                    microphone_audio_file_path = excluded.microphone_audio_file_path,
                    computer_audio_file_path = excluded.computer_audio_file_path,
                    diarization_status = excluded.diarization_status,
                    handoff_status = 'pending',
                    handoff_started_at = NULL,
                    handoff_completed_at = NULL,
                    handoff_content_hash = NULL,
                    handoff_error = NULL
                WHERE meetings.status <> 'done' AND meetings.is_archived = 0
                """,
                bindings: [
                    .text(meeting.id),
                    .text(meeting.title),
                    .text(meeting.captureSource.rawValue),
                    .real(meeting.createdAt.timeIntervalSince1970),
                    meeting.startedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                    meeting.endedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                    .text(try encodeRecordingIntervals(meeting.recordingIntervals)),
                    .text(try encodeDictionary(meeting.modelSnapshot)),
                    .text(try encodeDictionary(meeting.voiceprintSnapshot)),
                    meeting.audioFilePath.map(SQLiteValue.text) ?? .null,
                    meeting.microphoneAudioFilePath.map(SQLiteValue.text) ?? .null,
                    meeting.computerAudioFilePath.map(SQLiteValue.text) ?? .null,
                    .text(meeting.diarizationStatus.rawValue)
                ]
            )
            return try get(id: meeting.id)
        }
    }

    public func delete(id: String) throws {
        try database.execute(
            "DELETE FROM meetings WHERE id = ?",
            bindings: [.text(id)]
        )
    }

    private func decodeMeeting(_ row: [String: SQLiteValue]) throws -> Meeting {
        Meeting(
            id: row["id"]?.stringValue ?? "",
            title: row["title"]?.stringValue ?? "",
            status: MeetingStatus(rawValue: row["status"]?.stringValue ?? "") ?? .draft,
            captureSource: CaptureSource(rawValue: row["capture_source"]?.stringValue ?? "") ?? .microphone,
            createdAt: decodeDate(row["created_at"]) ?? Date(timeIntervalSince1970: 0),
            startedAt: decodeDate(row["started_at"]),
            endedAt: decodeDate(row["ended_at"]),
            recordingIntervals: decodeRecordingIntervals(row["recording_intervals"]?.stringValue),
            modelSnapshot: try decodeDictionary(row["model_snapshot"]?.stringValue ?? "{}"),
            voiceprintSnapshot: try decodeDictionary(row["voiceprint_snapshot"]?.stringValue ?? "{}"),
            isArchived: row["is_archived"]?.intValue == 1,
            handoffStatus: MeetingHandoffStatus(rawValue: row["handoff_status"]?.stringValue ?? "") ?? .ignored,
            handoffStartedAt: decodeDate(row["handoff_started_at"]),
            handoffCompletedAt: decodeDate(row["handoff_completed_at"]),
            handoffContentHash: row["handoff_content_hash"]?.stringValue,
            handoffError: row["handoff_error"]?.stringValue,
            audioFilePath: row["audio_file_path"]?.stringValue,
            microphoneAudioFilePath: row["microphone_audio_file_path"]?.stringValue,
            computerAudioFilePath: row["computer_audio_file_path"]?.stringValue,
            diarizationStatus: DiarizationStatus(rawValue: row["diarization_status"]?.stringValue ?? "") ?? .notStarted,
            minutesGenerationError: row["error_message"]?.stringValue
        )
    }

    private func decodeDate(_ value: SQLiteValue?) -> Date? {
        guard let value else {
            return nil
        }
        if let timestamp = value.doubleValue {
            return Date(timeIntervalSince1970: timestamp)
        }
        guard let text = value.stringValue, !text.isEmpty else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: text) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private func encodeDictionary(_ value: [String: String]) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeDictionary(_ value: String) throws -> [String: String] {
        try decoder.decode([String: String].self, from: Data(value.utf8))
    }

    private func encodeRecordingIntervals(_ value: [MeetingRecordingInterval]) throws -> String {
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeRecordingIntervals(_ value: String?) -> [MeetingRecordingInterval] {
        guard let value, !value.isEmpty,
              let data = value.data(using: .utf8) else {
            return []
        }
        return (try? decoder.decode([MeetingRecordingInterval].self, from: data)) ?? []
    }
}

public struct SegmentRepository: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func create(_ segment: TranscriptSegment) throws {
        let changes = try database.executeReturningChanges(
            """
            INSERT INTO transcript_segments (
                id, meeting_id, start_ms, end_ms, raw_text, processed_text,
                final_text, speaker_label, auto_speaker_label, source_track,
                person_id, person_name, confidence, is_manual, manual_reason
            )
            SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
            WHERE EXISTS (
                SELECT 1 FROM meetings
                WHERE id = ?
                  AND handoff_status NOT IN ('processing', 'completed')
            )
            """,
            bindings: [
                .text(segment.id),
                .text(segment.meetingID),
                .integer(Int64(segment.startMs)),
                .integer(Int64(segment.endMs)),
                .text(segment.rawText),
                .text(segment.processedText),
                .text(segment.finalText),
                .text(segment.speakerLabel),
                .text(segment.autoSpeakerLabel),
                segment.sourceTrack.map { .text($0.rawValue) } ?? .null,
                segment.personID.map(SQLiteValue.text) ?? .null,
                segment.personName.map(SQLiteValue.text) ?? .null,
                .real(segment.confidence),
                .integer(segment.isManual ? 1 : 0),
                segment.manualReason.map(SQLiteValue.text) ?? .null,
                .text(segment.meetingID)
            ]
        )
        guard changes > 0 else {
            throw MeetingRepositoryError.contentLockedByHandoff
        }
    }

    public func upsert(_ segment: TranscriptSegment) throws {
        let changes = try database.executeReturningChanges(
            """
            INSERT INTO transcript_segments (
                id, meeting_id, start_ms, end_ms, raw_text, processed_text,
                final_text, speaker_label, auto_speaker_label, source_track,
                person_id, person_name, confidence, is_manual, manual_reason
            )
            SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
            WHERE EXISTS (
                SELECT 1 FROM meetings
                WHERE id = ?
                  AND handoff_status NOT IN ('processing', 'completed')
            )
            ON CONFLICT(id) DO UPDATE SET
                meeting_id = excluded.meeting_id,
                start_ms = excluded.start_ms,
                end_ms = excluded.end_ms,
                raw_text = excluded.raw_text,
                processed_text = excluded.processed_text,
                final_text = excluded.final_text,
                speaker_label = excluded.speaker_label,
                auto_speaker_label = excluded.auto_speaker_label,
                source_track = excluded.source_track,
                person_id = excluded.person_id,
                person_name = excluded.person_name,
                confidence = excluded.confidence,
                is_manual = excluded.is_manual,
                manual_reason = excluded.manual_reason,
                updated_at = strftime('%s', 'now')
            WHERE EXISTS (
                SELECT 1 FROM meetings
                WHERE id = transcript_segments.meeting_id
                  AND handoff_status NOT IN ('processing', 'completed')
            )
            """,
            bindings: [
                .text(segment.id),
                .text(segment.meetingID),
                .integer(Int64(segment.startMs)),
                .integer(Int64(segment.endMs)),
                .text(segment.rawText),
                .text(segment.processedText),
                .text(segment.finalText),
                .text(segment.speakerLabel),
                .text(segment.autoSpeakerLabel),
                segment.sourceTrack.map { .text($0.rawValue) } ?? .null,
                segment.personID.map(SQLiteValue.text) ?? .null,
                segment.personName.map(SQLiteValue.text) ?? .null,
                .real(segment.confidence),
                .integer(segment.isManual ? 1 : 0),
                segment.manualReason.map(SQLiteValue.text) ?? .null,
                .text(segment.meetingID)
            ]
        )
        guard changes > 0 else {
            throw MeetingRepositoryError.contentLockedByHandoff
        }
    }

    public func delete(id: TranscriptSegment.ID) throws {
        let changes = try database.executeReturningChanges(
            """
            DELETE FROM transcript_segments
            WHERE id = ?
              AND EXISTS (
                  SELECT 1 FROM meetings
                  WHERE id = transcript_segments.meeting_id
                    AND handoff_status NOT IN ('processing', 'completed')
              )
            """,
            bindings: [.text(id)]
        )
        if changes == 0, try isContentLocked(segmentID: id) {
            throw MeetingRepositoryError.contentLockedByHandoff
        }
    }

    public func deleteAll(meetingID: String) throws {
        let changes = try database.executeReturningChanges(
            """
            DELETE FROM transcript_segments
            WHERE meeting_id = ?
              AND EXISTS (
                  SELECT 1 FROM meetings
                  WHERE id = ?
                    AND handoff_status NOT IN ('processing', 'completed')
              )
            """,
            bindings: [.text(meetingID), .text(meetingID)]
        )
        if changes == 0, try isContentLocked(meetingID: meetingID) {
            throw MeetingRepositoryError.contentLockedByHandoff
        }
    }

    func deleteAllForMeetingDeletion(meetingID: String) throws {
        try database.execute(
            "DELETE FROM transcript_segments WHERE meeting_id = ?",
            bindings: [.text(meetingID)]
        )
    }

    public func list(meetingID: String) throws -> [TranscriptSegment] {
        let rows = try database.query(
            "SELECT * FROM transcript_segments WHERE meeting_id = ? ORDER BY start_ms ASC",
            bindings: [.text(meetingID)]
        )
        return rows.map(decodeSegment)
    }

    /// 一次拉所有段并按 meeting_id 分组。用于 AppPersistenceStore.loadSnapshot，
    /// 避免"每个 meeting 一次子查询"的 N+1。
    public func listAllGroupedByMeeting() throws -> [String: [TranscriptSegment]] {
        let rows = try database.query(
            "SELECT * FROM transcript_segments ORDER BY meeting_id ASC, start_ms ASC"
        )
        var grouped: [String: [TranscriptSegment]] = [:]
        for row in rows {
            let segment = decodeSegment(row)
            grouped[segment.meetingID, default: []].append(segment)
        }
        return grouped
    }

    private func isContentLocked(segmentID: TranscriptSegment.ID) throws -> Bool {
        let rows = try database.query(
            """
            SELECT 1 AS locked
            FROM transcript_segments AS segment
            JOIN meetings ON meetings.id = segment.meeting_id
            WHERE segment.id = ?
              AND meetings.handoff_status IN ('processing', 'completed')
            LIMIT 1
            """,
            bindings: [.text(segmentID)]
        )
        return !rows.isEmpty
    }

    private func isContentLocked(meetingID: String) throws -> Bool {
        let rows = try database.query(
            """
            SELECT 1 AS locked
            FROM meetings
            WHERE id = ?
              AND handoff_status IN ('processing', 'completed')
            LIMIT 1
            """,
            bindings: [.text(meetingID)]
        )
        return !rows.isEmpty
    }

    private func decodeSegment(_ row: [String: SQLiteValue]) -> TranscriptSegment {
        TranscriptSegment(
            id: row["id"]?.stringValue ?? "",
            meetingID: row["meeting_id"]?.stringValue ?? "",
            startMs: row["start_ms"]?.intValue ?? 0,
            endMs: row["end_ms"]?.intValue ?? 0,
            speakerLabel: row["speaker_label"]?.stringValue ?? "",
            autoSpeakerLabel: row["auto_speaker_label"]?.stringValue ?? "",
            sourceTrack: row["source_track"]?.stringValue.flatMap { AudioCaptureTrack(rawValue: $0) },
            personID: row["person_id"]?.stringValue,
            personName: row["person_name"]?.stringValue,
            confidence: row["confidence"]?.doubleValue ?? 0,
            rawText: row["raw_text"]?.stringValue ?? "",
            processedText: row["processed_text"]?.stringValue ?? "",
            finalText: row["final_text"]?.stringValue ?? "",
            isManual: row["is_manual"]?.intValue == 1,
            manualReason: row["manual_reason"]?.stringValue
        )
    }
}

public enum MeetingNoteRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case contentLockedByHandoff

    public var errorDescription: String? {
        switch self {
        case .contentLockedByHandoff:
            "当前会议已进入交接流程，暂不可编辑笔记。"
        }
    }
}

public struct MeetingNoteRepository: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func upsert(_ note: MeetingNote) throws {
        let changes = try database.executeReturningChanges(
            """
            INSERT INTO meeting_notes (
                id, meeting_id, body, include_in_minutes, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                body = excluded.body,
                include_in_minutes = excluded.include_in_minutes,
                updated_at = excluded.updated_at
            WHERE EXISTS (
                SELECT 1 FROM meetings
                WHERE meetings.id = excluded.meeting_id
                  AND meetings.handoff_status NOT IN ('processing', 'completed')
            )
            """,
            bindings: [
                .text(note.id),
                .text(note.meetingID),
                .text(note.body),
                .integer(note.includeInMinutes ? 1 : 0),
                .real(note.createdAt.timeIntervalSince1970),
                .real(note.updatedAt.timeIntervalSince1970)
            ]
        )
        guard changes > 0 else {
            throw MeetingNoteRepositoryError.contentLockedByHandoff
        }
    }

    public func list(meetingID: Meeting.ID) throws -> [MeetingNote] {
        let rows = try database.query(
            """
            SELECT * FROM meeting_notes
            WHERE meeting_id = ?
            ORDER BY created_at ASC, id ASC
            """,
            bindings: [.text(meetingID)]
        )
        return rows.map(decodeNote)
    }

    public func listAllGroupedByMeeting() throws -> [Meeting.ID: [MeetingNote]] {
        let rows = try database.query(
            "SELECT * FROM meeting_notes ORDER BY meeting_id ASC, created_at ASC, id ASC"
        )
        var grouped: [Meeting.ID: [MeetingNote]] = [:]
        for row in rows {
            let note = decodeNote(row)
            grouped[note.meetingID, default: []].append(note)
        }
        return grouped
    }

    public func delete(id: MeetingNote.ID) throws {
        let changes = try database.executeReturningChanges(
            """
            DELETE FROM meeting_notes
            WHERE id = ?
              AND EXISTS (
                  SELECT 1 FROM meetings
                  WHERE meetings.id = meeting_notes.meeting_id
                    AND meetings.handoff_status NOT IN ('processing', 'completed')
              )
            """,
            bindings: [.text(id)]
        )
        guard changes > 0 else {
            throw MeetingNoteRepositoryError.contentLockedByHandoff
        }
    }

    public func deleteAllForMeetingDeletion(meetingID: Meeting.ID) throws {
        try database.execute(
            "DELETE FROM meeting_notes WHERE meeting_id = ?",
            bindings: [.text(meetingID)]
        )
    }

    private func decodeNote(_ row: [String: SQLiteValue]) -> MeetingNote {
        MeetingNote(
            id: row["id"]?.stringValue ?? "",
            meetingID: row["meeting_id"]?.stringValue ?? "",
            body: row["body"]?.stringValue ?? "",
            includeInMinutes: row["include_in_minutes"]?.intValue != 0,
            createdAt: decodeDate(row["created_at"]) ?? Date(timeIntervalSince1970: 0),
            updatedAt: decodeDate(row["updated_at"]) ?? Date(timeIntervalSince1970: 0)
        )
    }

    private func decodeDate(_ value: SQLiteValue?) -> Date? {
        guard let timestamp = value?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
}

public struct MeetingNoteImageRepository: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func upsert(_ image: MeetingNoteImage) throws {
        let changes = try database.executeReturningChanges(
            """
            INSERT INTO meeting_note_images (
                id, note_id, filename, mime_type, original_data, thumbnail_data, sha256,
                vision_status, vision_text, vision_model, vision_prompt_version,
                vision_updated_at, vision_error, created_at, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                filename = excluded.filename,
                mime_type = excluded.mime_type,
                original_data = excluded.original_data,
                thumbnail_data = excluded.thumbnail_data,
                sha256 = excluded.sha256,
                vision_status = excluded.vision_status,
                vision_text = excluded.vision_text,
                vision_model = excluded.vision_model,
                vision_prompt_version = excluded.vision_prompt_version,
                vision_updated_at = excluded.vision_updated_at,
                vision_error = excluded.vision_error,
                updated_at = excluded.updated_at
            WHERE EXISTS (
                SELECT 1
                FROM meeting_notes
                JOIN meetings ON meetings.id = meeting_notes.meeting_id
                WHERE meeting_notes.id = excluded.note_id
                  AND meetings.handoff_status NOT IN ('processing', 'completed')
            )
            """,
            bindings: [
                .text(image.id),
                .text(image.noteID),
                .text(image.filename),
                .text(image.mimeType),
                .blob(image.originalData ?? Data()),
                .blob(image.thumbnailData),
                .text(image.sha256),
                .text(image.visionStatus.rawValue),
                .text(image.visionText),
                image.visionModel.map(SQLiteValue.text) ?? .null,
                image.visionPromptVersion.map(SQLiteValue.text) ?? .null,
                image.visionUpdatedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                image.visionError.map(SQLiteValue.text) ?? .null,
                .real(image.createdAt.timeIntervalSince1970),
                .real(image.updatedAt.timeIntervalSince1970)
            ]
        )
        guard changes > 0 else {
            throw MeetingNoteRepositoryError.contentLockedByHandoff
        }
    }

    public func list(
        meetingID: Meeting.ID,
        includeOriginalData: Bool = false
    ) throws -> [MeetingNoteImage] {
        let originalColumn = includeOriginalData ? "original_data" : "NULL AS original_data"
        let rows = try database.query(
            """
            SELECT
                images.id, images.note_id, images.filename, images.mime_type,
                \(originalColumn), images.thumbnail_data, images.sha256,
                images.vision_status, images.vision_text, images.vision_model,
                images.vision_prompt_version, images.vision_updated_at, images.vision_error,
                images.created_at, images.updated_at
            FROM meeting_note_images AS images
            JOIN meeting_notes AS notes ON notes.id = images.note_id
            WHERE notes.meeting_id = ?
            ORDER BY images.created_at ASC, images.id ASC
            """,
            bindings: [.text(meetingID)]
        )
        return rows.map(decodeImage)
    }

    public func listAllGroupedByMeeting() throws -> [Meeting.ID: [MeetingNoteImage]] {
        let rows = try database.query(
            """
            SELECT
                images.id, images.note_id, images.filename, images.mime_type,
                NULL AS original_data, images.thumbnail_data, images.sha256,
                images.vision_status, images.vision_text, images.vision_model,
                images.vision_prompt_version, images.vision_updated_at, images.vision_error,
                images.created_at, images.updated_at, notes.meeting_id
            FROM meeting_note_images AS images
            JOIN meeting_notes AS notes ON notes.id = images.note_id
            ORDER BY notes.meeting_id ASC, images.created_at ASC, images.id ASC
            """
        )
        var grouped: [Meeting.ID: [MeetingNoteImage]] = [:]
        for row in rows {
            let meetingID = row["meeting_id"]?.stringValue ?? ""
            grouped[meetingID, default: []].append(decodeImage(row))
        }
        return grouped
    }

    public func updateVision(
        id: MeetingNoteImage.ID,
        status: MeetingNoteVisionStatus,
        text: String = "",
        model: String? = nil,
        promptVersion: String? = nil,
        error: String? = nil,
        updatedAt: Date = Date()
    ) throws {
        try database.execute(
            """
            UPDATE meeting_note_images
            SET vision_status = ?, vision_text = ?, vision_model = ?,
                vision_prompt_version = ?, vision_updated_at = ?, vision_error = ?,
                updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .text(status.rawValue),
                .text(text),
                model.map(SQLiteValue.text) ?? .null,
                promptVersion.map(SQLiteValue.text) ?? .null,
                .real(updatedAt.timeIntervalSince1970),
                error.map(SQLiteValue.text) ?? .null,
                .real(updatedAt.timeIntervalSince1970),
                .text(id)
            ]
        )
    }

    public func delete(id: MeetingNoteImage.ID) throws {
        let changes = try database.executeReturningChanges(
            """
            DELETE FROM meeting_note_images
            WHERE id = ?
              AND EXISTS (
                  SELECT 1
                  FROM meeting_notes
                  JOIN meetings ON meetings.id = meeting_notes.meeting_id
                  WHERE meeting_notes.id = meeting_note_images.note_id
                    AND meetings.handoff_status NOT IN ('processing', 'completed')
              )
            """,
            bindings: [.text(id)]
        )
        guard changes > 0 else {
            throw MeetingNoteRepositoryError.contentLockedByHandoff
        }
    }

    private func decodeImage(_ row: [String: SQLiteValue]) -> MeetingNoteImage {
        MeetingNoteImage(
            id: row["id"]?.stringValue ?? "",
            noteID: row["note_id"]?.stringValue ?? "",
            filename: row["filename"]?.stringValue ?? "",
            mimeType: row["mime_type"]?.stringValue ?? "image/jpeg",
            originalData: row["original_data"]?.dataValue,
            thumbnailData: row["thumbnail_data"]?.dataValue ?? Data(),
            sha256: row["sha256"]?.stringValue ?? "",
            visionStatus: MeetingNoteVisionStatus(rawValue: row["vision_status"]?.stringValue ?? "") ?? .pending,
            visionText: row["vision_text"]?.stringValue ?? "",
            visionModel: row["vision_model"]?.stringValue,
            visionPromptVersion: row["vision_prompt_version"]?.stringValue,
            visionUpdatedAt: decodeDate(row["vision_updated_at"]),
            visionError: row["vision_error"]?.stringValue,
            createdAt: decodeDate(row["created_at"]) ?? Date(timeIntervalSince1970: 0),
            updatedAt: decodeDate(row["updated_at"]) ?? Date(timeIntervalSince1970: 0)
        )
    }

    private func decodeDate(_ value: SQLiteValue?) -> Date? {
        guard let timestamp = value?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
}

public struct PeopleRepository: Sendable {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: Database) {
        self.database = database
    }

    public func create(_ person: VoiceprintPerson) throws {
        try database.execute(
            """
            INSERT INTO people (
                id, display_name, aliases, job_title, role_tags, responsibilities,
                zentao_account, zentao_user_id, threshold, is_active, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%s', 'now'))
            """,
            bindings: [
                .text(person.id),
                .text(person.displayName),
                .text(try encodeAliases(person.aliases)),
                .text(person.jobTitle),
                .text(try encodeAliases(person.roleTags)),
                .text(person.responsibilities),
                .text(person.zentaoAccount),
                .text(person.zentaoUserID),
                .real(person.threshold),
                .integer(person.isActive ? 1 : 0)
            ]
        )
    }

    public func upsert(_ person: VoiceprintPerson) throws {
        try database.execute(
            """
            INSERT INTO people (
                id, display_name, aliases, job_title, role_tags, responsibilities,
                zentao_account, zentao_user_id, threshold, is_active, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, strftime('%s', 'now'))
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                aliases = excluded.aliases,
                job_title = excluded.job_title,
                role_tags = excluded.role_tags,
                responsibilities = excluded.responsibilities,
                zentao_account = excluded.zentao_account,
                zentao_user_id = excluded.zentao_user_id,
                threshold = excluded.threshold,
                is_active = excluded.is_active,
                updated_at = strftime('%s', 'now')
            """,
            bindings: [
                .text(person.id),
                .text(person.displayName),
                .text(try encodeAliases(person.aliases)),
                .text(person.jobTitle),
                .text(try encodeAliases(person.roleTags)),
                .text(person.responsibilities),
                .text(person.zentaoAccount),
                .text(person.zentaoUserID),
                .real(person.threshold),
                .integer(person.isActive ? 1 : 0)
            ]
        )
    }

    public func list() throws -> [VoiceprintPerson] {
        let rows = try database.query(
            """
            SELECT * FROM people
            ORDER BY
                CASE WHEN created_at IS NULL THEN 0 ELSE 1 END DESC,
                CAST(created_at AS REAL) DESC,
                rowid DESC
            """
        )
        return try rows.map(decodePerson)
    }

    public func delete(id: VoiceprintPerson.ID) throws {
        try database.transaction {
            try database.execute(
                "DELETE FROM voiceprint_samples WHERE person_id = ?",
                bindings: [.text(id)]
            )
            try database.execute("DELETE FROM people WHERE id = ?", bindings: [.text(id)])
        }
    }

    private func decodePerson(_ row: [String: SQLiteValue]) throws -> VoiceprintPerson {
        VoiceprintPerson(
            id: row["id"]?.stringValue ?? "",
            displayName: row["display_name"]?.stringValue ?? "",
            aliases: try decodeAliases(row["aliases"]?.stringValue ?? "[]"),
            jobTitle: row["job_title"]?.stringValue ?? "",
            roleTags: try decodeAliases(row["role_tags"]?.stringValue ?? "[]"),
            responsibilities: row["responsibilities"]?.stringValue ?? "",
            zentaoAccount: row["zentao_account"]?.stringValue ?? "",
            zentaoUserID: row["zentao_user_id"]?.stringValue ?? "",
            threshold: row["threshold"]?.doubleValue ?? VoiceprintMatchingPolicy.minimumPersonThreshold,
            isActive: row["is_active"]?.intValue == 1
        )
    }

    private func encodeAliases(_ aliases: [String]) throws -> String {
        let data = try encoder.encode(aliases)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeAliases(_ aliases: String) throws -> [String] {
        try decoder.decode([String].self, from: Data(aliases.utf8))
    }
}

public struct TerminologyRepository: Sendable {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: Database) {
        self.database = database
    }

    public func upsert(_ entry: TerminologyEntry) throws {
        try database.execute(
            """
            INSERT INTO terminology_entries (
                id, canonical_name, aliases, category, notes, is_active, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, strftime('%s', 'now'), strftime('%s', 'now'))
            ON CONFLICT(id) DO UPDATE SET
                canonical_name = excluded.canonical_name,
                aliases = excluded.aliases,
                category = excluded.category,
                notes = excluded.notes,
                is_active = excluded.is_active,
                updated_at = strftime('%s', 'now')
            """,
            bindings: [
                .text(entry.id),
                .text(entry.canonicalName),
                .text(try encode(entry.aliases)),
                .text(entry.category),
                .text(entry.notes),
                .integer(entry.isActive ? 1 : 0)
            ]
        )
    }

    public func list() throws -> [TerminologyEntry] {
        try database.query(
            "SELECT * FROM terminology_entries ORDER BY canonical_name ASC"
        ).map { row in
            TerminologyEntry(
                id: row["id"]?.stringValue ?? "",
                canonicalName: row["canonical_name"]?.stringValue ?? "",
                aliases: try decode(row["aliases"]?.stringValue ?? "[]"),
                category: row["category"]?.stringValue ?? "",
                notes: row["notes"]?.stringValue ?? "",
                isActive: row["is_active"]?.intValue == 1
            )
        }
    }

    public func delete(id: TerminologyEntry.ID) throws {
        try database.execute(
            "DELETE FROM terminology_entries WHERE id = ?",
            bindings: [.text(id)]
        )
    }

    private func encode(_ values: [String]) throws -> String {
        String(decoding: try encoder.encode(values), as: UTF8.self)
    }

    private func decode(_ value: String) throws -> [String] {
        try decoder.decode([String].self, from: Data(value.utf8))
    }
}

public struct VoiceprintSampleRepository: Sendable {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: Database) {
        self.database = database
    }

    public func upsert(_ sample: VoiceprintSample) throws {
        try database.execute(
            """
            INSERT INTO voiceprint_samples (
                id, person_id, source_meeting_id, source_segment_id,
                embedding, audio_ref, duration_ms, quality_score, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                person_id = excluded.person_id,
                source_meeting_id = excluded.source_meeting_id,
                source_segment_id = excluded.source_segment_id,
                embedding = excluded.embedding,
                audio_ref = excluded.audio_ref,
                duration_ms = excluded.duration_ms,
                quality_score = excluded.quality_score,
                created_at = excluded.created_at
            """,
            bindings: [
                .text(sample.id),
                .text(sample.personID),
                sample.sourceMeetingID.map(SQLiteValue.text) ?? .null,
                sample.sourceSegmentID.map(SQLiteValue.text) ?? .null,
                .text(try encodeEmbedding(sample.embedding)),
                sample.audioRef.map(SQLiteValue.text) ?? .null,
                .integer(Int64(sample.durationMs)),
                .real(sample.qualityScore),
                .real(sample.createdAt.timeIntervalSince1970)
            ]
        )
    }

    public func list() throws -> [VoiceprintSample] {
        let rows = try database.query("SELECT * FROM voiceprint_samples ORDER BY created_at ASC")
        return rows.map(decodeSample)
    }

    public func list(personID: String) throws -> [VoiceprintSample] {
        let rows = try database.query(
            "SELECT * FROM voiceprint_samples WHERE person_id = ? ORDER BY created_at ASC",
            bindings: [.text(personID)]
        )
        return rows.map(decodeSample)
    }

    private func decodeSample(_ row: [String: SQLiteValue]) -> VoiceprintSample {
        VoiceprintSample(
            id: row["id"]?.stringValue ?? "",
            personID: row["person_id"]?.stringValue ?? "",
            sourceMeetingID: row["source_meeting_id"]?.stringValue,
            sourceSegmentID: row["source_segment_id"]?.stringValue,
            embedding: decodeEmbedding(row["embedding"]?.stringValue ?? "[]"),
            audioRef: row["audio_ref"]?.stringValue,
            durationMs: row["duration_ms"]?.intValue ?? 0,
            qualityScore: row["quality_score"]?.doubleValue ?? 0,
            createdAt: decodeDate(row["created_at"]) ?? Date(timeIntervalSince1970: 0)
        )
    }

    private func encodeEmbedding(_ embedding: [Double]) throws -> String {
        let data = try encoder.encode(embedding)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeEmbedding(_ embedding: String) -> [Double] {
        (try? decoder.decode([Double].self, from: Data(embedding.utf8))) ?? []
    }

    private func decodeDate(_ value: SQLiteValue?) -> Date? {
        guard let value else {
            return nil
        }
        if let timestamp = value.doubleValue {
            return Date(timeIntervalSince1970: timestamp)
        }
        guard let text = value.stringValue, !text.isEmpty else {
            return nil
        }
        if let timestamp = Double(text) {
            return Date(timeIntervalSince1970: timestamp)
        }
        return ISO8601DateFormatter().date(from: text)
    }
}

public enum ModelSourceRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case alreadyExists(id: ModelSource.ID)
    case missingSecureAPIKey(reference: String)
    case secureStorageFailure(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .alreadyExists(id):
            "模型服务已存在（\(id)）"
        case let .missingSecureAPIKey(reference):
            "未在 Keychain 中找到模型服务 API Key（\(reference)）"
        case let .secureStorageFailure(reason):
            "模型 API Key 安全存储失败：\(reason)"
        }
    }
}

public struct ModelSourceRepository: Sendable {
    private let database: Database
    private let apiKeyStore: any ModelSourceAPIKeyStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        database: Database,
        apiKeyStore: any ModelSourceAPIKeyStore = KeychainModelSourceAPIKeyStore()
    ) {
        self.database = database
        self.apiKeyStore = apiKeyStore
    }

    /// 旧版本 Keychain 条目的引用格式，仅用于一次性回迁。
    public static func apiKeyReference(for sourceID: ModelSource.ID) -> String {
        "model-source-api-key:\(sourceID)"
    }

    /// 把旧版本 Keychain 中的 API Key 静默迁回 SQLite。无论成功或失败都会清空引用，避免重复授权弹窗。
    public func migrateLegacyKeychainAPIKeysToPlaintext() throws {
        let rows = try database.query(
            """
            SELECT id, api_key, api_key_ref
            FROM model_sources
            WHERE api_key_ref IS NOT NULL
              AND length(trim(api_key_ref)) > 0
              AND (api_key IS NULL OR length(trim(api_key)) = 0)
            """
        )

        for row in rows {
            guard let sourceID = row["id"]?.stringValue,
                  let reference = normalizedReference(row["api_key_ref"]?.stringValue)
            else {
                continue
            }

            do {
                if let apiKey = try apiKeyStore.apiKey(for: reference), !apiKey.isEmpty {
                    try database.execute(
                        "UPDATE model_sources SET api_key = ?, api_key_ref = NULL WHERE id = ?",
                        bindings: [.text(apiKey), .text(sourceID)]
                    )
                } else {
                    try markLegacyKeychainMigrationFailed(id: sourceID)
                }
            } catch {
                try markLegacyKeychainMigrationFailed(id: sourceID)
            }
        }
    }

    public func create(_ source: ModelSource) throws {
        let existing = try database.query(
            "SELECT 1 FROM model_sources WHERE id = ? LIMIT 1",
            bindings: [.text(source.id)]
        )
        guard existing.isEmpty else {
            throw ModelSourceRepositoryError.alreadyExists(id: source.id)
        }

        try save(source, conflictClause: "")
    }

    public func upsert(_ source: ModelSource) throws {
        try save(
            source,
            conflictClause: """
            ON CONFLICT(id) DO UPDATE SET
                type = excluded.type,
                name = excluded.name,
                base_url = excluded.base_url,
                api_key = excluded.api_key,
                api_key_ref = excluded.api_key_ref,
                api_protocol = excluded.api_protocol,
                meeting_minutes_max_concurrency = excluded.meeting_minutes_max_concurrency,
                supports_vision = excluded.supports_vision,
                selected_model = excluded.selected_model,
                available_models = excluded.available_models,
                is_default = excluded.is_default,
                enabled = excluded.enabled,
                last_test_ok = excluded.last_test_ok,
                last_test_message = excluded.last_test_message,
                last_test_at = excluded.last_test_at,
                updated_at = strftime('%s', 'now')
            """
        )
    }

    public func list() throws -> [ModelSource] {
        let rows = try database.query("SELECT * FROM model_sources ORDER BY name ASC")
        return try rows.map(decodeSource)
    }

    public func delete(id: ModelSource.ID) throws {
        try database.execute(
            "DELETE FROM model_sources WHERE id = ?",
            bindings: [.text(id)]
        )
    }

    private func save(_ source: ModelSource, conflictClause: String) throws {
        try database.execute(
            """
            INSERT INTO model_sources (
                id, type, name, base_url, api_key, api_key_ref, api_protocol,
                meeting_minutes_max_concurrency,
                supports_vision,
                selected_model, available_models, is_default, enabled,
                last_test_ok, last_test_message, last_test_at
            )
            VALUES (?, ?, ?, ?, ?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            \(conflictClause)
            """,
            bindings: [
                .text(source.id),
                .text(source.type.rawValue),
                .text(source.name),
                .text(source.baseURL),
                .text(source.apiKey),
                .text(source.apiProtocol.rawValue),
                source.meetingMinutesMaximumConcurrency.map { .integer(Int64($0)) } ?? .null,
                .integer(source.supportsVision ? 1 : 0),
                source.selectedModel.map(SQLiteValue.text) ?? .null,
                .text(try encodeModels(source.availableModels)),
                .integer(source.isDefault ? 1 : 0),
                .integer(source.enabled ? 1 : 0),
                source.lastTestOK.map { .integer($0 ? 1 : 0) } ?? .null,
                source.lastTestMessage.map(SQLiteValue.text) ?? .null,
                source.lastTestAt.map { .real($0.timeIntervalSince1970) } ?? .null
            ]
        )
    }

    private func decodeSource(_ row: [String: SQLiteValue]) throws -> ModelSource {
        let sourceType = ModelSourceType(rawValue: row["type"]?.stringValue ?? "") ?? .asr
        let apiProtocol = ModelAPIProtocol(rawValue: row["api_protocol"]?.stringValue ?? "") ?? .chatCompletions
        let maximumConcurrency = row["meeting_minutes_max_concurrency"]?.intValue
        let supportsVision = row["supports_vision"]?.intValue == 1
        let id = row["id"]?.stringValue ?? ""
        let name = row["name"]?.stringValue ?? ""
        let baseURL = row["base_url"]?.stringValue ?? ""
        let apiKey = row["api_key"]?.stringValue ?? ""
        let selectedModel = row["selected_model"]?.stringValue
        let availableModels = decodeModels(row["available_models"]?.stringValue ?? "[]")
        let isDefault = row["is_default"]?.intValue == 1
        let enabled = row["enabled"]?.intValue == 1
        let lastTestOK = row["last_test_ok"]?.intValue.map { $0 == 1 }
        let lastTestMessage = row["last_test_message"]?.stringValue
        let lastTestAt = decodeDate(row["last_test_at"])
        return ModelSource(
            id: id,
            type: sourceType,
            name: name,
            baseURL: baseURL,
            apiKey: apiKey,
            apiProtocol: apiProtocol,
            selectedModel: selectedModel,
            availableModels: availableModels,
            isDefault: isDefault,
            enabled: enabled,
            meetingMinutesMaximumConcurrency: maximumConcurrency,
            supportsVision: supportsVision,
            lastTestOK: lastTestOK,
            lastTestMessage: lastTestMessage,
            lastTestAt: lastTestAt
        )
    }

    private func markLegacyKeychainMigrationFailed(id: ModelSource.ID) throws {
        try database.execute(
            """
            UPDATE model_sources
            SET api_key = '',
                api_key_ref = NULL,
                enabled = 0,
                last_test_ok = 0,
                last_test_message = '旧钥匙串密钥无法静默迁移，请重新录入一次',
                last_test_at = ?,
                updated_at = strftime('%s', 'now')
            WHERE id = ?
            """,
            bindings: [.real(Date().timeIntervalSince1970), .text(id)]
        )
    }

    private func normalizedReference(_ reference: String?) -> String? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reference.isEmpty
        else {
            return nil
        }
        return reference
    }

    private func encodeModels(_ models: [String]) throws -> String {
        let data = try encoder.encode(models)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeModels(_ models: String) -> [String] {
        (try? decoder.decode([String].self, from: Data(models.utf8))) ?? []
    }

    private func decodeDate(_ value: SQLiteValue?) -> Date? {
        guard let value else {
            return nil
        }
        if let timestamp = value.doubleValue {
            return Date(timeIntervalSince1970: timestamp)
        }
        guard let text = value.stringValue, !text.isEmpty else {
            return nil
        }
        if let timestamp = Double(text) {
            return Date(timeIntervalSince1970: timestamp)
        }
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: text) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}


public struct DiarizationRunRepository: Sendable {
    private let database: Database
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: Database) {
        self.database = database
    }

    public func upsert(_ run: DiarizationRun) throws {
        try database.execute(
            """
            INSERT INTO diarization_runs (
                id, meeting_id, scope, status, audio_file_path,
                turns, error_message, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                meeting_id = excluded.meeting_id,
                scope = excluded.scope,
                status = excluded.status,
                audio_file_path = excluded.audio_file_path,
                turns = excluded.turns,
                error_message = excluded.error_message,
                created_at = excluded.created_at
            """,
            bindings: [
                .text(run.id),
                .text(run.meetingID),
                .text(run.scope.rawValue),
                .text(run.status.rawValue),
                .text(run.audioFilePath),
                .text(try encodeTurns(run.turns)),
                run.errorMessage.map(SQLiteValue.text) ?? .null,
                .real(run.createdAt.timeIntervalSince1970)
            ]
        )
    }

    public func list(meetingID: String) throws -> [DiarizationRun] {
        let rows = try database.query(
            "SELECT * FROM diarization_runs WHERE meeting_id = ? ORDER BY created_at ASC",
            bindings: [.text(meetingID)]
        )
        return rows.map(decodeRun)
    }

    public func listAllGroupedByMeeting() throws -> [String: [DiarizationRun]] {
        let rows = try database.query(
            "SELECT * FROM diarization_runs ORDER BY meeting_id ASC, created_at ASC"
        )
        var grouped: [String: [DiarizationRun]] = [:]
        for row in rows {
            let run = decodeRun(row)
            grouped[run.meetingID, default: []].append(run)
        }
        return grouped
    }

    public func deleteAll(meetingID: String) throws {
        try database.execute(
            "DELETE FROM diarization_runs WHERE meeting_id = ?",
            bindings: [.text(meetingID)]
        )
    }

    private func decodeRun(_ row: [String: SQLiteValue]) -> DiarizationRun {
        DiarizationRun(
            id: row["id"]?.stringValue ?? "",
            meetingID: row["meeting_id"]?.stringValue ?? "",
            scope: DiarizationRunScope(rawValue: row["scope"]?.stringValue ?? "") ?? .rolling,
            status: DiarizationRunStatus(rawValue: row["status"]?.stringValue ?? "") ?? .failed,
            audioFilePath: row["audio_file_path"]?.stringValue ?? "",
            turns: decodeTurns(row["turns"]?.stringValue ?? "[]"),
            errorMessage: row["error_message"]?.stringValue,
            createdAt: decodeDate(row["created_at"]) ?? Date(timeIntervalSince1970: 0)
        )
    }

    private func encodeTurns(_ turns: [DiarizationTurn]) throws -> String {
        let data = try encoder.encode(turns)
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeTurns(_ turns: String) -> [DiarizationTurn] {
        (try? decoder.decode([DiarizationTurn].self, from: Data(turns.utf8))) ?? []
    }

    private func decodeDate(_ value: SQLiteValue?) -> Date? {
        guard let value else {
            return nil
        }
        if let timestamp = value.doubleValue {
            return Date(timeIntervalSince1970: timestamp)
        }
        return nil
    }
}

public struct DiarizationSpeakerMappingRepository: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func upsert(_ mapping: DiarizationSpeakerMapping) throws {
        try database.execute(
            """
            INSERT INTO diarization_speaker_mappings (
                id, meeting_id, speaker_key, speaker_label,
                person_id, person_name, confidence, is_manual, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(meeting_id, speaker_key) DO UPDATE SET
                speaker_label = excluded.speaker_label,
                person_id = excluded.person_id,
                person_name = excluded.person_name,
                confidence = excluded.confidence,
                is_manual = excluded.is_manual,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text("\(mapping.meetingID)_\(mapping.speakerKey)"),
                .text(mapping.meetingID),
                .text(mapping.speakerKey),
                .text(mapping.speakerLabel),
                mapping.personID.map(SQLiteValue.text) ?? .null,
                mapping.personName.map(SQLiteValue.text) ?? .null,
                .real(mapping.confidence),
                .integer(mapping.isManual ? 1 : 0),
                .real(Date().timeIntervalSince1970)
            ]
        )
    }

    public func list(meetingID: String) throws -> [DiarizationSpeakerMapping] {
        let rows = try database.query(
            "SELECT * FROM diarization_speaker_mappings WHERE meeting_id = ? ORDER BY speaker_label ASC",
            bindings: [.text(meetingID)]
        )
        return rows.map(decodeMapping)
    }

    public func listAllGroupedByMeeting() throws -> [String: [DiarizationSpeakerMapping]] {
        let rows = try database.query(
            "SELECT * FROM diarization_speaker_mappings ORDER BY meeting_id ASC, speaker_label ASC"
        )
        var grouped: [String: [DiarizationSpeakerMapping]] = [:]
        for row in rows {
            let mapping = decodeMapping(row)
            grouped[mapping.meetingID, default: []].append(mapping)
        }
        return grouped
    }

    public func deleteAll(meetingID: String) throws {
        try database.execute(
            "DELETE FROM diarization_speaker_mappings WHERE meeting_id = ?",
            bindings: [.text(meetingID)]
        )
    }

    private func decodeMapping(_ row: [String: SQLiteValue]) -> DiarizationSpeakerMapping {
        DiarizationSpeakerMapping(
            meetingID: row["meeting_id"]?.stringValue ?? "",
            speakerKey: row["speaker_key"]?.stringValue ?? "",
            speakerLabel: row["speaker_label"]?.stringValue ?? "",
            personID: row["person_id"]?.stringValue,
            personName: row["person_name"]?.stringValue,
            confidence: row["confidence"]?.doubleValue ?? 0,
            isManual: row["is_manual"]?.intValue == 1
        )
    }
}

public struct AppSettingRepository: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    public func get(_ key: String) throws -> String? {
        let rows = try database.query("SELECT value FROM app_settings WHERE key = ?", bindings: [.text(key)])
        return rows.first?["value"]?.stringValue
    }

    public func set(_ key: String, value: String) throws {
        try database.execute(
            """
            INSERT INTO app_settings (key, value, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at
            """,
            bindings: [
                .text(key),
                .text(value),
                .real(Date().timeIntervalSince1970)
            ]
        )
    }
}
