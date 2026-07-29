import Foundation
import SQLite3

public struct AppPersistenceSnapshot: Sendable {
    public var meetings: [Meeting]
    public var segmentsByMeeting: [Meeting.ID: [TranscriptSegment]]
    public var notesByMeeting: [Meeting.ID: [MeetingNote]]
    public var noteImagesByMeeting: [Meeting.ID: [MeetingNoteImage]]
    public var people: [VoiceprintPerson]
    public var terminologyEntries: [TerminologyEntry]
    public var voiceprintSamples: [VoiceprintSample]
    public var diarizationRunsByMeeting: [Meeting.ID: [DiarizationRun]]
    public var diarizationMappingsByMeeting: [Meeting.ID: [DiarizationSpeakerMapping]]
    public var meetingAgentMessagesByMeeting: [Meeting.ID: [MeetingAgentChatMessage]]
    public var modelSources: [ModelSource]
    public var appSettings: [String: String]

    public init(
        meetings: [Meeting],
        segmentsByMeeting: [Meeting.ID: [TranscriptSegment]],
        notesByMeeting: [Meeting.ID: [MeetingNote]] = [:],
        noteImagesByMeeting: [Meeting.ID: [MeetingNoteImage]] = [:],
        people: [VoiceprintPerson],
        terminologyEntries: [TerminologyEntry] = [],
        voiceprintSamples: [VoiceprintSample] = [],
        diarizationRunsByMeeting: [Meeting.ID: [DiarizationRun]] = [:],
        diarizationMappingsByMeeting: [Meeting.ID: [DiarizationSpeakerMapping]] = [:],
        meetingAgentMessagesByMeeting: [Meeting.ID: [MeetingAgentChatMessage]] = [:],
        modelSources: [ModelSource],
        appSettings: [String: String] = [:]
    ) {
        self.meetings = meetings
        self.segmentsByMeeting = segmentsByMeeting
        self.notesByMeeting = notesByMeeting
        self.noteImagesByMeeting = noteImagesByMeeting
        self.people = people
        self.terminologyEntries = terminologyEntries
        self.voiceprintSamples = voiceprintSamples
        self.diarizationRunsByMeeting = diarizationRunsByMeeting
        self.diarizationMappingsByMeeting = diarizationMappingsByMeeting
        self.meetingAgentMessagesByMeeting = meetingAgentMessagesByMeeting
        self.modelSources = modelSources
        self.appSettings = appSettings
    }
}

/// App 持久化层可向上层公开的故障原因；上层应显式处理 `.unavailable`，而不是使用 `store?` 静默跳过写入。
public enum AppPersistenceStoreError: Error, Equatable, LocalizedError, Sendable {
    case unavailable(reason: String)
    case closed
    case secureStorageUnavailable(reason: String)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(reason):
            "持久化不可用：\(reason)"
        case .closed:
            "持久化已关闭"
        case let .secureStorageUnavailable(reason):
            "安全存储不可用：\(reason)"
        }
    }
}

public enum TranscriptImportPersistenceError: Error, Equatable, LocalizedError, Sendable {
    case emptySegments
    case meetingMismatch

    public var errorDescription: String? {
        switch self {
        case .emptySegments:
            "没有可保存的转写片段。"
        case .meetingMismatch:
            "转写片段不属于同一场会议。"
        }
    }
}

public enum AppPersistenceAvailability: Equatable, Sendable {
    case available
    case unavailable(AppPersistenceStoreError)
}

/// 显式建库结果，供上层避免 `try?` / optional chaining 掩盖持久化失败。
public enum AppPersistenceStoreOpenResult: Sendable {
    case available(AppPersistenceStore)
    case unavailable(AppPersistenceStoreError)
}

public final class AppPersistenceStore: @unchecked Sendable {
    private let database: Database
    private let meetings: MeetingRepository
    private let segments: SegmentRepository
    private let notes: MeetingNoteRepository
    private let noteImages: MeetingNoteImageRepository
    private let people: PeopleRepository
    private let terminology: TerminologyRepository
    private let voiceprintSamples: VoiceprintSampleRepository
    private let diarizationRuns: DiarizationRunRepository
    private let diarizationMappings: DiarizationSpeakerMappingRepository
    private let models: ModelSourceRepository
    private let settings: AppSettingRepository
    private let meetingAgentJobs: MeetingAgentJobRepository
    private let meetingAgentResults: MeetingAgentResultRepository
    private let meetingTodos: MeetingTodoRepository
    private let meetingAgentChat: MeetingAgentChatRepository
    private let availabilityLock = NSLock()
    private var currentAvailability: AppPersistenceAvailability = .available

    /// 保持既有 `throws` 初始化 API；需要无异常分支时请使用 `open(path:apiKeyStore:)`。
    public init(
        path: String = AppPersistenceStore.defaultDatabasePath(),
        apiKeyStore: any ModelSourceAPIKeyStore = KeychainModelSourceAPIKeyStore()
    ) throws {
        do {
            let url = URL(fileURLWithPath: path)
            let directory = url.deletingLastPathComponent()
            let directoryAlreadyExisted = FileManager.default.fileExists(atPath: directory.path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.migrateLegacyDefaultDatabaseIfNeeded(destinationURL: url)
            // 只收紧本应用目录或本次新建目录，绝不修改调用者传入的共享父目录（例如 /tmp）。
            if !directoryAlreadyExisted || directory.lastPathComponent == "会小纪" {
                try Self.restrictPermissions(of: directory, to: 0o700)
            }

            let database = try Database(path: path)
            try Self.restrictPermissions(of: url, to: 0o600)
            try database.migrate()

            let models = ModelSourceRepository(database: database, apiKeyStore: apiKeyStore)
            try models.migrateLegacyKeychainAPIKeysToPlaintext()

            self.database = database
            meetings = MeetingRepository(database: database)
            segments = SegmentRepository(database: database)
            notes = MeetingNoteRepository(database: database)
            noteImages = MeetingNoteImageRepository(database: database)
            people = PeopleRepository(database: database)
            terminology = TerminologyRepository(database: database)
            voiceprintSamples = VoiceprintSampleRepository(database: database)
            diarizationRuns = DiarizationRunRepository(database: database)
            diarizationMappings = DiarizationSpeakerMappingRepository(database: database)
            self.models = models
            settings = AppSettingRepository(database: database)
            meetingAgentJobs = MeetingAgentJobRepository(database: database)
            meetingAgentResults = MeetingAgentResultRepository(database: database)
            meetingTodos = MeetingTodoRepository(database: database)
            meetingAgentChat = MeetingAgentChatRepository(database: database)
        } catch {
            throw Self.initializationError(from: error)
        }
    }

    public static func open(
        path: String = AppPersistenceStore.defaultDatabasePath(),
        apiKeyStore: any ModelSourceAPIKeyStore = KeychainModelSourceAPIKeyStore()
    ) -> AppPersistenceStoreOpenResult {
        do {
            return .available(try AppPersistenceStore(path: path, apiKeyStore: apiKeyStore))
        } catch let error as AppPersistenceStoreError {
            return .unavailable(error)
        } catch {
            return .unavailable(initializationError(from: error))
        }
    }

    public var availability: AppPersistenceAvailability {
        availabilityLock.lock()
        defer { availabilityLock.unlock() }
        return currentAvailability
    }

    public var isAvailable: Bool {
        availability == .available
    }

    public static func defaultDatabasePath() -> String {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return applicationSupport
            .appendingPathComponent("会小纪", isDirectory: true)
            .appendingPathComponent("ai-tingji.sqlite")
            .path
    }

    static func migrateLegacyDatabaseIfNeeded(destinationURL: URL, legacyDatabaseURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyDatabaseURL.path),
              try meetingCount(at: legacyDatabaseURL) > 0,
              try meetingCount(at: destinationURL) == 0
        else {
            return
        }

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        for suffix in ["", "-wal", "-shm"] {
            let path = destinationURL.path + suffix
            if fileManager.fileExists(atPath: path) {
                try fileManager.removeItem(atPath: path)
            }
        }

        var source: OpaquePointer?
        var destination: OpaquePointer?
        guard sqlite3_open_v2(legacyDatabaseURL.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let source
        else {
            let message = source.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
            if let source { sqlite3_close_v2(source) }
            throw DatabaseError.openFailed(message)
        }
        defer { sqlite3_close_v2(source) }

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(destinationURL.path, &destination, flags, nil) == SQLITE_OK,
              let destination
        else {
            let message = destination.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
            if let destination { sqlite3_close_v2(destination) }
            throw DatabaseError.openFailed(message)
        }
        defer { sqlite3_close_v2(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            let message = String(cString: sqlite3_errmsg(destination))
            throw DatabaseError.executeFailed(message)
        }
        defer { sqlite3_backup_finish(backup) }

        guard sqlite3_backup_step(backup, -1) == SQLITE_DONE else {
            throw DatabaseError.executeFailed(String(cString: sqlite3_errmsg(destination)))
        }
    }

    private static func migrateLegacyDefaultDatabaseIfNeeded(destinationURL: URL) throws {
        let expectedDestination = URL(fileURLWithPath: defaultDatabasePath()).standardizedFileURL
        guard destinationURL.standardizedFileURL == expectedDestination else {
            return
        }

        let applicationSupport = destinationURL.deletingLastPathComponent().deletingLastPathComponent()
        let legacyDatabaseURL = applicationSupport
            .appendingPathComponent("听澜", isDirectory: true)
            .appendingPathComponent("ai-tingji.sqlite")
        try migrateLegacyDatabaseIfNeeded(destinationURL: destinationURL, legacyDatabaseURL: legacyDatabaseURL)
    }

    private static func meetingCount(at url: URL) throws -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return 0
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
            if let database { sqlite3_close_v2(database) }
            throw DatabaseError.openFailed(message)
        }
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM meetings", -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            return 0
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.stepFailed(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    public func close() {
        database.close()
        setAvailability(.unavailable(.closed))
    }

    public func loadSnapshot() throws -> AppPersistenceSnapshot {
        try requireAvailable()
        let allMeetings = try meetings.list()
        // 用批量分组接口一次拉齐，避免"每个 meeting 3 次子查询"的 N+1。
        let segmentsByMeeting = try segments.listAllGroupedByMeeting()
        let notesByMeeting = try notes.listAllGroupedByMeeting()
        let noteImagesByMeeting = try noteImages.listAllGroupedByMeeting()
        let diarizationRunsByMeeting = try diarizationRuns.listAllGroupedByMeeting()
        let diarizationMappingsByMeeting = try diarizationMappings.listAllGroupedByMeeting()

        return AppPersistenceSnapshot(
            meetings: allMeetings,
            segmentsByMeeting: segmentsByMeeting,
            notesByMeeting: notesByMeeting,
            noteImagesByMeeting: noteImagesByMeeting,
            people: try people.list(),
            terminologyEntries: try terminology.list(),
            voiceprintSamples: try voiceprintSamples.list(),
            diarizationRunsByMeeting: diarizationRunsByMeeting,
            diarizationMappingsByMeeting: diarizationMappingsByMeeting,
            meetingAgentMessagesByMeeting: try meetingAgentChat.listAllGroupedByMeeting(),
            modelSources: try models.list(),
            appSettings: [
                AppSettingKey.postprocessPrompt: try settings.get(AppSettingKey.postprocessPrompt)
                    ?? PostprocessPrompt.defaultMouthFillerCleanup,
                AppSettingKey.meetingMinutesPrompt: try settings.get(AppSettingKey.meetingMinutesPrompt)
                    ?? PostprocessPrompt.meetingMinutes,
                AppSettingKey.meetingMinutesPromptVersion: try settings.get(AppSettingKey.meetingMinutesPromptVersion) ?? "0",
                AppSettingKey.meetingAnalysisPrompt: try settings.get(AppSettingKey.meetingAnalysisPrompt)
                    ?? PostprocessPrompt.meetingAnalysis,
                AppSettingKey.diarizationSpeakerPreset: try settings.get(AppSettingKey.diarizationSpeakerPreset)
                    ?? DiarizationSpeakerPreset.automatic.rawValue,
                AppSettingKey.microphoneDeviceID: try settings.get(AppSettingKey.microphoneDeviceID) ?? "",
                AppSettingKey.pendingPostprocessMeetingIDs: try settings.get(AppSettingKey.pendingPostprocessMeetingIDs) ?? "[]",
                AppSettingKey.meetingMinutesModelSeeded: try settings.get(AppSettingKey.meetingMinutesModelSeeded) ?? "false",
                AppSettingKey.difyKnowledgeBaseConfiguration: try settings.get(AppSettingKey.difyKnowledgeBaseConfiguration) ?? "",
                AppSettingKey.currentUserPersonID: try settings.get(AppSettingKey.currentUserPersonID) ?? "",
                AppSettingKey.meetingAgentWorkspacePath: try settings.get(AppSettingKey.meetingAgentWorkspacePath) ?? ""
            ]
        )
    }

    public func upsertMeeting(_ meeting: Meeting) throws {
        try requireAvailable()
        try meetings.upsert(meeting)
    }

    public func importTranscriptMeeting(
        _ meeting: Meeting,
        segments importedSegments: [TranscriptSegment]
    ) throws {
        try requireAvailable()
        guard !importedSegments.isEmpty else {
            throw TranscriptImportPersistenceError.emptySegments
        }
        guard importedSegments.allSatisfy({ $0.meetingID == meeting.id }) else {
            throw TranscriptImportPersistenceError.meetingMismatch
        }
        try database.transaction {
            try meetings.create(meeting)
            for segment in importedSegments {
                try segments.create(segment)
            }
        }
    }

    public func updateGeneratedMeetingTitle(
        id: Meeting.ID,
        expectedTitle: String,
        title: String
    ) throws -> Meeting? {
        try requireAvailable()
        return try meetings.updateGeneratedTitle(
            id: id,
            expectedTitle: expectedTitle,
            title: title
        )
    }

    public func loadMeetings() throws -> [Meeting] {
        try requireAvailable()
        return try meetings.list()
    }

    public func setMeetingArchived(
        id: Meeting.ID,
        isArchived: Bool,
        restoredHandoffStatus: MeetingHandoffStatus? = nil
    ) throws {
        try requireAvailable()
        try meetings.setArchived(
            id: id,
            isArchived: isArchived,
            restoredHandoffStatus: restoredHandoffStatus
        )
    }

    @discardableResult
    public func persistMeetingReadyForHandoff(_ meeting: Meeting) throws -> Meeting {
        try requireAvailable()
        return try meetings.persistReadyForHandoff(meeting)
    }

    public func upsertSegment(_ segment: TranscriptSegment) throws {
        try requireAvailable()
        try segments.upsert(segment)
    }

    public func deleteSegment(id: TranscriptSegment.ID) throws {
        try requireAvailable()
        try segments.delete(id: id)
    }

    public func loadMeetingNotes(
        meetingID: Meeting.ID,
        includeOriginalData: Bool = false
    ) throws -> ([MeetingNote], [MeetingNoteImage]) {
        try requireAvailable()
        return (
            try notes.list(meetingID: meetingID),
            try noteImages.list(meetingID: meetingID, includeOriginalData: includeOriginalData)
        )
    }

    public func upsertMeetingNote(_ note: MeetingNote) throws {
        try requireAvailable()
        try notes.upsert(note)
    }

    public func deleteMeetingNote(id: MeetingNote.ID) throws {
        try requireAvailable()
        try notes.delete(id: id)
    }

    public func upsertMeetingNoteImage(_ image: MeetingNoteImage) throws {
        try requireAvailable()
        try noteImages.upsert(image)
    }

    public func updateMeetingNoteImageVision(
        id: MeetingNoteImage.ID,
        status: MeetingNoteVisionStatus,
        text: String = "",
        model: String? = nil,
        promptVersion: String? = nil,
        error: String? = nil,
        updatedAt: Date = Date()
    ) throws {
        try requireAvailable()
        try noteImages.updateVision(
            id: id,
            status: status,
            text: text,
            model: model,
            promptVersion: promptVersion,
            error: error,
            updatedAt: updatedAt
        )
    }

    public func deleteMeetingNoteImage(id: MeetingNoteImage.ID) throws {
        try requireAvailable()
        try noteImages.delete(id: id)
    }

    public func deleteMeeting(id: Meeting.ID) throws {
        try requireAvailable()
        try database.transaction {
            try database.execute(
                "DELETE FROM manual_overrides WHERE meeting_id = ?",
                bindings: [.text(id)]
            )
            try diarizationMappings.deleteAll(meetingID: id)
            try diarizationRuns.deleteAll(meetingID: id)
            try database.execute(
                "DELETE FROM meeting_unknown_speakers WHERE meeting_id = ?",
                bindings: [.text(id)]
            )
            try notes.deleteAllForMeetingDeletion(meetingID: id)
            try segments.deleteAllForMeetingDeletion(meetingID: id)
            try database.execute(
                "DELETE FROM export_jobs WHERE meeting_id = ?",
                bindings: [.text(id)]
            )
            try meetings.delete(id: id)
        }
    }

    public func upsertPerson(_ person: VoiceprintPerson) throws {
        try requireAvailable()
        try people.upsert(person)
    }

    public func deletePerson(id: VoiceprintPerson.ID) throws {
        try requireAvailable()
        try people.delete(id: id)
    }

    public func upsertTerminologyEntry(_ entry: TerminologyEntry) throws {
        try requireAvailable()
        try terminology.upsert(entry)
    }

    public func deleteTerminologyEntry(id: TerminologyEntry.ID) throws {
        try requireAvailable()
        try terminology.delete(id: id)
    }

    public func upsertVoiceprintSample(_ sample: VoiceprintSample) throws {
        try requireAvailable()
        try voiceprintSamples.upsert(sample)
    }

    public func upsertDiarizationRun(_ run: DiarizationRun) throws {
        try requireAvailable()
        try diarizationRuns.upsert(run)
    }

    public func upsertDiarizationSpeakerMapping(_ mapping: DiarizationSpeakerMapping) throws {
        try requireAvailable()
        try diarizationMappings.upsert(mapping)
    }

    public func deleteDiarizationSpeakerMappings(meetingID: Meeting.ID) throws {
        try requireAvailable()
        try diarizationMappings.deleteAll(meetingID: meetingID)
    }

    public func upsertModelSource(_ source: ModelSource) throws {
        try requireAvailable()
        try models.upsert(source)
    }

    public func deleteModelSource(id: ModelSource.ID) throws {
        try requireAvailable()
        try models.delete(id: id)
    }

    public func setAppSetting(_ key: String, value: String) throws {
        try requireAvailable()
        try settings.set(key, value: value)
    }

    public func createMeetingAgentJob(_ job: MeetingAgentJob) throws {
        try requireAvailable()
        try meetingAgentJobs.create(job)
    }

    @discardableResult
    public func transitionMeetingAgentJob(
        id: MeetingAgentJob.ID,
        from source: MeetingAgentJobStatus,
        to target: MeetingAgentJobStatus,
        expectedUpdatedAt: Date,
        updatedAt: Date
    ) throws -> Bool {
        try requireAvailable()
        return try meetingAgentJobs.transition(
            id: id,
            from: source,
            to: target,
            expectedUpdatedAt: expectedUpdatedAt,
            updatedAt: updatedAt
        )
    }

    @discardableResult
    public func markMeetingAgentJobFailed(
        id: MeetingAgentJob.ID,
        from source: MeetingAgentJobStatus,
        expectedUpdatedAt: Date,
        errorCode: String,
        errorMessage: String,
        updatedAt: Date
    ) throws -> Bool {
        try requireAvailable()
        return try meetingAgentJobs.markFailed(
            id: id,
            from: source,
            expectedUpdatedAt: expectedUpdatedAt,
            errorCode: errorCode,
            errorMessage: errorMessage,
            updatedAt: updatedAt
        )
    }

    public func loadMeetingAgentJob(id: MeetingAgentJob.ID) throws -> MeetingAgentJob? {
        try requireAvailable()
        return try meetingAgentJobs.get(id: id)
    }

    public func loadMeetingAgentJobs(meetingID: Meeting.ID) throws -> [MeetingAgentJob] {
        try requireAvailable()
        return try meetingAgentJobs.list(meetingID: meetingID)
    }

    public func loadMeetingAgentResult(jobID: MeetingAgentJob.ID) throws -> MeetingAgentResult? {
        try requireAvailable()
        return try meetingAgentResults.get(jobID: jobID)
    }

    public func loadMeetingTodos(meetingID: Meeting.ID) throws -> [MeetingTodo] {
        try requireAvailable()
        return try meetingTodos.list(meetingID: meetingID)
    }

    public func upsertMeetingAgentChatMessage(_ message: MeetingAgentChatMessage) throws {
        try requireAvailable()
        try meetingAgentChat.upsert(message)
    }

    public func loadMeetingAgentChatMessages(meetingID: Meeting.ID) throws -> [MeetingAgentChatMessage] {
        try requireAvailable()
        return try meetingAgentChat.list(meetingID: meetingID)
    }

    @discardableResult
    public func importMeetingAgentResult(
        jobID: MeetingAgentJob.ID,
        result: MeetingAgentResult,
        todos: [MeetingTodo]
    ) throws -> MeetingAgentResult {
        try requireAvailable()
        return try database.transaction {
            guard let job = try meetingAgentJobs.get(id: jobID) else {
                throw DatabaseError.missingRow
            }
            guard result.id == jobID, result.jobID == jobID, result.meetingID == job.meetingID,
                  todos.allSatisfy({ $0.jobID == jobID && $0.meetingID == job.meetingID })
            else {
                throw MeetingAgentRepositoryError.identityMismatch
            }
            guard Self.isSafeMeetingAgentRelativePath(result.manifestRelativePath),
                  Self.isSafeMeetingAgentRelativePath(result.reportRelativePath),
                  Self.isSHA256(result.manifestSHA256),
                  Self.areValidInitialTodos(todos)
            else {
                throw MeetingAgentRepositoryError.invalidRecord
            }

            let persistedResult: MeetingAgentResult
            if let existing = try meetingAgentResults.get(jobID: jobID) {
                guard meetingAgentResults.representsSamePackage(existing, result) else {
                    throw MeetingAgentRepositoryError.resultConflict
                }
                if job.status == .ready {
                    return existing
                }
                persistedResult = existing
            } else {
                guard job.status == .importing else {
                    throw MeetingAgentRepositoryError.stateConflict
                }
                try meetingAgentResults.create(result)
                persistedResult = result
            }

            guard job.status == .importing else {
                throw MeetingAgentRepositoryError.stateConflict
            }
            if try meetingTodos.count(jobID: jobID) == 0 {
                for todo in todos {
                    try meetingTodos.create(todo)
                }
            }

            let changes = try database.executeReturningChanges(
                """
                UPDATE meeting_agent_jobs
                SET status = 'ready', result_relative_path = ?, updated_at = ?, completed_at = ?
                WHERE id = ? AND status = 'importing'
                """,
                bindings: [
                    .text(persistedResult.reportRelativePath),
                    .real(persistedResult.importedAt.timeIntervalSince1970),
                    .real(persistedResult.importedAt.timeIntervalSince1970),
                    .text(jobID)
                ]
            )
            guard changes == 1 else {
                throw MeetingAgentRepositoryError.stateConflict
            }
            return persistedResult
        }
    }

    private static func isSafeMeetingAgentRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func areValidInitialTodos(_ todos: [MeetingTodo]) -> Bool {
        let identifiers = todos.map(\.todoID)
        guard Set(identifiers).count == identifiers.count else {
            return false
        }
        return todos.allSatisfy { todo in
            let hasIdentity = !todo.todoID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !todo.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let validAssignmentValues = todo.owner.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true
                && (todo.deadline.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true)
            let validEvidence = todo.evidence.allSatisfy { evidence in
                !evidence.segmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !evidence.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !evidence.timeRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let hasAssignment = todo.owner != nil || todo.deadline != nil
            let assignmentHasEvidence = !hasAssignment || !todo.evidence.isEmpty
            return hasIdentity
                && todo.confirmationStatus == .pendingConfirmation
                && validAssignmentValues
                && validEvidence
                && assignmentHasEvidence
        }
    }

    private func requireAvailable() throws {
        guard case let .unavailable(error) = availability else {
            return
        }
        throw error
    }

    private func setAvailability(_ availability: AppPersistenceAvailability) {
        availabilityLock.lock()
        currentAvailability = availability
        availabilityLock.unlock()
    }

    private static func restrictPermissions(of url: URL, to permissions: Int16) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }

    private static func initializationError(from error: Error) -> AppPersistenceStoreError {
        if let error = error as? AppPersistenceStoreError {
            return error
        }
        if error is ModelSourceAPIKeyStoreError || error is ModelSourceRepositoryError {
            return .secureStorageUnavailable(reason: error.localizedDescription)
        }
        return .unavailable(reason: error.localizedDescription)
    }
}

public enum AppSettingKey {
    public static let postprocessPrompt = "postprocess_prompt"
    public static let meetingMinutesPrompt = "meeting_minutes_prompt"
    public static let meetingMinutesPromptVersion = "meeting_minutes_prompt_version"
    public static let meetingAnalysisPrompt = "meeting_analysis_prompt"
    public static let diarizationSpeakerPreset = "diarization_speaker_preset"
    public static let microphoneDeviceID = "microphone_device_id"
    public static let pendingPostprocessMeetingIDs = "pending_postprocess_meeting_ids"
    public static let meetingMinutesModelSeeded = "meeting_minutes_model_seeded"
    public static let difyKnowledgeBaseConfiguration = "dify_knowledge_base_configuration"
    public static let currentUserPersonID = "current_user_person_id"
    public static let meetingAgentWorkspacePath = "meeting_agent_workspace_path"
}
