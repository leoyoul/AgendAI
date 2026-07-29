import Foundation
import SQLite3

public enum DatabaseError: Error, Equatable, Sendable {
    case openFailed(String)
    case executeFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case missingRow
}

public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    /// SQLite handle 只能被单线程访问，Repository 层可能来自 MainActor 或后台 Task；
    /// 全部路由到这个串行队列避免竞态与 statement handle 损坏。
    private let queue = DispatchQueue(label: "com.aitingji.database.serial")
    private static let queueSpecificKey = DispatchSpecificKey<ObjectIdentifier>()

    private func performSync<T>(_ work: () throws -> T) rethrows -> T {
        // 支持 transaction 内嵌套调用 execute/query：如果已经在自己的 serial queue 上，
        // 直接执行；否则 queue.sync 切过来。
        if DispatchQueue.getSpecific(key: Self.queueSpecificKey) == ObjectIdentifier(self) {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    public init(path: String) throws {
        var db: OpaquePointer?
        // SQLITE_OPEN_FULLMUTEX 保证 sqlite 自身也走 serialized threading mode，
        // 与外层 serial queue 一起做双保险。
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown"
            if let db { sqlite3_close_v2(db) }
            throw DatabaseError.openFailed(message)
        }
        self.handle = db
        queue.setSpecific(key: Self.queueSpecificKey, value: ObjectIdentifier(self))
        _ = try query("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA busy_timeout=5000;")
        try execute("PRAGMA foreign_keys=ON;")
    }

    deinit {
        // deinit 不能走 queue.sync：调用方可能已经持有 queue，导致死锁。
        // deinit 时进程/队列语义保证不会再有其他访问，直接 close 即可。
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    public func close() {
        performSync {
            if let handle {
                sqlite3_close_v2(handle)
                self.handle = nil
            }
        }
    }

    public func migrate() throws {
        try execute(Self.schema)
        try migrateMeetingTodosToCompositePrimaryKey()
        // `api_key_ref` 仅用于把旧版本 Keychain 数据一次性迁回 `api_key`。
        try addColumnIfMissing(table: "model_sources", column: "api_key_ref", definition: "TEXT")
        try addColumnIfMissing(
            table: "model_sources",
            column: "api_protocol",
            definition: "TEXT NOT NULL DEFAULT 'chat_completions'"
        )
        try addColumnIfMissing(
            table: "model_sources",
            column: "meeting_minutes_max_concurrency",
            definition: "INTEGER DEFAULT 1"
        )
        try addColumnIfMissing(
            table: "model_sources",
            column: "supports_vision",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        try addColumnIfMissing(table: "people", column: "job_title", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "people", column: "role_tags", definition: "TEXT NOT NULL DEFAULT '[]'")
        try addColumnIfMissing(table: "people", column: "responsibilities", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "people", column: "zentao_account", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "people", column: "zentao_user_id", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "meetings", column: "is_archived", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "meetings", column: "audio_file_path", definition: "TEXT")
        try addColumnIfMissing(table: "meetings", column: "microphone_audio_file_path", definition: "TEXT")
        try addColumnIfMissing(table: "meetings", column: "computer_audio_file_path", definition: "TEXT")
        try addColumnIfMissing(table: "meetings", column: "recording_intervals", definition: "TEXT NOT NULL DEFAULT '[]'")
        try addColumnIfMissing(table: "meetings", column: "diarization_status", definition: "TEXT NOT NULL DEFAULT 'not_started'")
        try addColumnIfMissing(table: "meetings", column: "handoff_status", definition: "TEXT NOT NULL DEFAULT 'ignored'")
        try addColumnIfMissing(table: "meetings", column: "handoff_started_at", definition: "REAL")
        try addColumnIfMissing(table: "meetings", column: "handoff_completed_at", definition: "REAL")
        try addColumnIfMissing(table: "meetings", column: "handoff_content_hash", definition: "TEXT")
        try addColumnIfMissing(table: "meetings", column: "handoff_error", definition: "TEXT")
        try addColumnIfMissing(table: "transcript_segments", column: "source_track", definition: "TEXT")
        try addColumnIfMissing(table: "diarization_speaker_mappings", column: "is_manual", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(
            table: "meeting_agent_chat_messages",
            column: "timeline_json",
            definition: "TEXT NOT NULL DEFAULT '[]'"
        )
        try decommissionHandoffWorkflow()
        try createHotPathIndexes()
    }

    private func decommissionHandoffWorkflow() throws {
        try transaction {
            try execute(
                """
                DROP TRIGGER IF EXISTS trg_meetings_handoff_title_changed;
                DROP TRIGGER IF EXISTS trg_segments_handoff_inserted;
                DROP TRIGGER IF EXISTS trg_segments_handoff_updated;
                DROP TRIGGER IF EXISTS trg_segments_handoff_deleted;
                DROP INDEX IF EXISTS idx_meetings_handoff_pending;

                UPDATE meetings
                SET handoff_status = 'ignored',
                    handoff_started_at = NULL,
                    handoff_completed_at = NULL,
                    handoff_content_hash = NULL,
                    handoff_error = NULL
                WHERE handoff_status <> 'ignored'
                   OR handoff_started_at IS NOT NULL
                   OR handoff_completed_at IS NOT NULL
                   OR handoff_content_hash IS NOT NULL
                   OR handoff_error IS NOT NULL;
                """
            )
        }
    }

    private func migrateMeetingTodosToCompositePrimaryKey() throws {
        let columns = try query("PRAGMA table_info(meeting_todos);")
        let primaryKeyOrder = Dictionary(uniqueKeysWithValues: columns.compactMap { row -> (String, Int)? in
            guard let name = row["name"]?.stringValue, let order = row["pk"]?.intValue, order > 0 else {
                return nil
            }
            return (name, order)
        })
        guard primaryKeyOrder != ["job_id": 1, "id": 2] else {
            return
        }

        try transaction {
            try execute(
                """
                DROP TABLE IF EXISTS meeting_todos_v2;
                CREATE TABLE meeting_todos_v2 (
                    id TEXT NOT NULL,
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
                    updated_at REAL NOT NULL,
                    PRIMARY KEY(job_id, id),
                    FOREIGN KEY(job_id) REFERENCES meeting_agent_jobs(id) ON DELETE CASCADE,
                    FOREIGN KEY(meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
                );

                INSERT INTO meeting_todos_v2 (
                    id, job_id, meeting_id, title, detail, owner, deadline, deliverable,
                    acceptance_criteria, evidence_json, confirmation_status, proposed_workflow,
                    created_at, updated_at
                )
                SELECT
                    id, job_id, meeting_id, title, detail, owner, deadline, deliverable,
                    acceptance_criteria, evidence_json, confirmation_status, proposed_workflow,
                    created_at, updated_at
                FROM meeting_todos;

                DROP TABLE meeting_todos;
                ALTER TABLE meeting_todos_v2 RENAME TO meeting_todos;
                """
            )
        }
    }

    /// 热点索引：现在所有涉及 meeting_id 的查询都会走全表扫。
    /// 会议数一多，UI 冷启动和快照加载会明显卡顿。
    private func createHotPathIndexes() throws {
        let statements = [
            "CREATE INDEX IF NOT EXISTS idx_segments_meeting_start ON transcript_segments(meeting_id, start_ms);",
            "CREATE INDEX IF NOT EXISTS idx_runs_meeting ON diarization_runs(meeting_id);",
            "CREATE INDEX IF NOT EXISTS idx_mappings_meeting_key ON diarization_speaker_mappings(meeting_id, speaker_key);",
            "CREATE INDEX IF NOT EXISTS idx_samples_person ON voiceprint_samples(person_id);",
            "CREATE INDEX IF NOT EXISTS idx_manual_overrides_segment ON manual_overrides(segment_id);",
            "CREATE INDEX IF NOT EXISTS idx_meetings_archived_created ON meetings(is_archived, created_at DESC);",
            "CREATE INDEX IF NOT EXISTS idx_unknown_speakers_meeting ON meeting_unknown_speakers(meeting_id);",
            "CREATE INDEX IF NOT EXISTS idx_terminology_canonical ON terminology_entries(canonical_name);",
            "CREATE INDEX IF NOT EXISTS idx_agent_jobs_meeting_created ON meeting_agent_jobs(meeting_id, created_at DESC);",
            "CREATE INDEX IF NOT EXISTS idx_agent_jobs_status_updated ON meeting_agent_jobs(status, updated_at);",
            "CREATE INDEX IF NOT EXISTS idx_agent_results_meeting_imported ON meeting_agent_results(meeting_id, imported_at DESC);",
            "CREATE INDEX IF NOT EXISTS idx_meeting_todos_meeting_status ON meeting_todos(meeting_id, confirmation_status, created_at);",
            "CREATE INDEX IF NOT EXISTS idx_meeting_todos_job ON meeting_todos(job_id);",
            "CREATE INDEX IF NOT EXISTS idx_agent_chat_meeting_created ON meeting_agent_chat_messages(meeting_id, created_at);",
            "CREATE INDEX IF NOT EXISTS idx_meeting_notes_meeting_created ON meeting_notes(meeting_id, created_at);",
            "CREATE INDEX IF NOT EXISTS idx_meeting_note_images_note_created ON meeting_note_images(note_id, created_at);"
        ]
        for sql in statements {
            try execute(sql)
        }
    }

    public func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        try performSync {
            try _execute(sql, bindings: bindings)
        }
    }

    public func executeReturningChanges(_ sql: String, bindings: [SQLiteValue] = []) throws -> Int {
        try performSync {
            try _execute(sql, bindings: bindings)
            return Int(sqlite3_changes(handle))
        }
    }

    public func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[String: SQLiteValue]] {
        try performSync {
            try _query(sql, bindings: bindings)
        }
    }

    /// 事务包装：BEGIN IMMEDIATE / COMMIT / ROLLBACK。批量写入务必走这里。
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try performSync {
            try _execute("BEGIN IMMEDIATE;", bindings: [])
            do {
                let result = try body()
                try _execute("COMMIT;", bindings: [])
                return result
            } catch {
                try? _execute("ROLLBACK;", bindings: [])
                throw error
            }
        }
    }

    private func _execute(_ sql: String, bindings: [SQLiteValue]) throws {
        if bindings.isEmpty {
            var error: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
                let message = error.map { String(cString: $0) } ?? errorMessage
                sqlite3_free(error)
                throw DatabaseError.executeFailed(message)
            }
            return
        }

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        if sqlite3_step(statement) != SQLITE_DONE {
            throw DatabaseError.executeFailed(errorMessage)
        }
    }

    private func _query(_ sql: String, bindings: [SQLiteValue]) throws -> [[String: SQLiteValue]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var rows: [[String: SQLiteValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return rows
            }
            guard result == SQLITE_ROW else {
                throw DatabaseError.stepFailed(errorMessage)
            }
            var row: [String: SQLiteValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                row[name] = SQLiteValue(statement: statement, index: index)
            }
            rows.append(row)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(errorMessage)
        }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case let .integer(value):
                result = sqlite3_bind_int64(statement, index, value)
            case let .real(value):
                result = sqlite3_bind_double(statement, index, value)
            case let .text(value):
                result = sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
            case let .blob(value):
                result = value.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        statement,
                        index,
                        bytes.baseAddress,
                        Int32(value.count),
                        SQLITE_TRANSIENT
                    )
                }
            }
            guard result == SQLITE_OK else {
                throw DatabaseError.executeFailed(errorMessage)
            }
        }
    }

    private var errorMessage: String {
        guard let handle, let message = sqlite3_errmsg(handle) else {
            return "unknown"
        }
        return String(cString: message)
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        let rows = try query("PRAGMA table_info(\(table));")
        let existingColumns = Set(rows.compactMap { $0["name"]?.stringValue })
        guard !existingColumns.contains(column) else {
            return
        }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    private static let schema = """
    CREATE TABLE IF NOT EXISTS model_sources (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        name TEXT NOT NULL,
        base_url TEXT NOT NULL,
        -- 单机版按用户选择直接保存 API Key；数据库文件权限固定为 0600。
        api_key TEXT NOT NULL DEFAULT '',
        api_key_ref TEXT,
        api_protocol TEXT NOT NULL DEFAULT 'chat_completions',
        meeting_minutes_max_concurrency INTEGER DEFAULT 1,
        supports_vision INTEGER NOT NULL DEFAULT 0,
        selected_model TEXT,
        available_models TEXT NOT NULL DEFAULT '[]',
        is_default INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 1,
        last_test_ok INTEGER,
        last_test_message TEXT,
        last_test_at TEXT,
        created_at TEXT,
        updated_at TEXT
    );

    CREATE TABLE IF NOT EXISTS people (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        aliases TEXT NOT NULL DEFAULT '[]',
        job_title TEXT NOT NULL DEFAULT '',
        role_tags TEXT NOT NULL DEFAULT '[]',
        responsibilities TEXT NOT NULL DEFAULT '',
        zentao_account TEXT NOT NULL DEFAULT '',
        zentao_user_id TEXT NOT NULL DEFAULT '',
        notes TEXT,
        threshold REAL NOT NULL DEFAULT 0.95,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT,
        updated_at TEXT
    );

    CREATE TABLE IF NOT EXISTS terminology_entries (
        id TEXT PRIMARY KEY,
        canonical_name TEXT NOT NULL,
        aliases TEXT NOT NULL DEFAULT '[]',
        category TEXT NOT NULL DEFAULT '',
        notes TEXT NOT NULL DEFAULT '',
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT,
        updated_at TEXT
    );

    CREATE TABLE IF NOT EXISTS meetings (
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
        handoff_status TEXT NOT NULL DEFAULT 'ignored',
        handoff_started_at REAL,
        handoff_completed_at REAL,
        handoff_content_hash TEXT,
        handoff_error TEXT,
        audio_file_path TEXT,
        microphone_audio_file_path TEXT,
        computer_audio_file_path TEXT,
        diarization_status TEXT NOT NULL DEFAULT 'not_started',
        error_message TEXT
    );

    CREATE TABLE IF NOT EXISTS transcript_segments (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL,
        start_ms INTEGER NOT NULL,
        end_ms INTEGER NOT NULL,
        raw_text TEXT NOT NULL DEFAULT '',
        processed_text TEXT NOT NULL DEFAULT '',
        final_text TEXT NOT NULL DEFAULT '',
        speaker_label TEXT NOT NULL,
        auto_speaker_label TEXT NOT NULL DEFAULT '',
        source_track TEXT,
        person_id TEXT,
        person_name TEXT,
        confidence REAL NOT NULL DEFAULT 0,
        is_manual INTEGER NOT NULL DEFAULT 0,
        manual_reason TEXT,
        merged_into_id TEXT,
        created_at REAL,
        updated_at REAL,
        FOREIGN KEY(meeting_id) REFERENCES meetings(id)
    );

    CREATE TABLE IF NOT EXISTS meeting_notes (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL,
        body TEXT NOT NULL DEFAULT '',
        include_in_minutes INTEGER NOT NULL DEFAULT 1,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        FOREIGN KEY(meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS meeting_note_images (
        id TEXT PRIMARY KEY,
        note_id TEXT NOT NULL,
        filename TEXT NOT NULL DEFAULT '',
        mime_type TEXT NOT NULL,
        original_data BLOB NOT NULL,
        thumbnail_data BLOB NOT NULL DEFAULT X'',
        sha256 TEXT NOT NULL,
        vision_status TEXT NOT NULL DEFAULT 'pending',
        vision_text TEXT NOT NULL DEFAULT '',
        vision_model TEXT,
        vision_prompt_version TEXT,
        vision_updated_at REAL,
        vision_error TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        FOREIGN KEY(note_id) REFERENCES meeting_notes(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS meeting_agent_jobs (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL,
        request_hash TEXT NOT NULL,
        provider TEXT NOT NULL,
        status TEXT NOT NULL,
        analysis_goal TEXT NOT NULL DEFAULT '',
        result_relative_path TEXT,
        error_code TEXT,
        error_message TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        completed_at REAL,
        FOREIGN KEY(meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS meeting_agent_results (
        id TEXT PRIMARY KEY,
        job_id TEXT NOT NULL UNIQUE,
        meeting_id TEXT NOT NULL,
        manifest_relative_path TEXT NOT NULL,
        report_relative_path TEXT NOT NULL,
        manifest_sha256 TEXT NOT NULL,
        imported_at REAL NOT NULL,
        FOREIGN KEY(job_id) REFERENCES meeting_agent_jobs(id) ON DELETE CASCADE,
        FOREIGN KEY(meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS meeting_todos (
        id TEXT NOT NULL,
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
        updated_at REAL NOT NULL,
        PRIMARY KEY(job_id, id),
        FOREIGN KEY(job_id) REFERENCES meeting_agent_jobs(id) ON DELETE CASCADE,
        FOREIGN KEY(meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS meeting_agent_chat_messages (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL DEFAULT '',
        reasoning TEXT NOT NULL DEFAULT '',
        activity_json TEXT NOT NULL DEFAULT '[]',
        timeline_json TEXT NOT NULL DEFAULT '[]',
        status TEXT NOT NULL DEFAULT 'completed',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        FOREIGN KEY(meeting_id) REFERENCES meetings(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS voiceprint_samples (
        id TEXT PRIMARY KEY,
        person_id TEXT NOT NULL,
        source_meeting_id TEXT,
        source_segment_id TEXT,
        embedding TEXT NOT NULL DEFAULT '[]',
        audio_ref TEXT,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        quality_score REAL NOT NULL DEFAULT 0,
        created_at REAL,
        FOREIGN KEY(person_id) REFERENCES people(id)
    );

    CREATE TABLE IF NOT EXISTS meeting_unknown_speakers (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL,
        unknown_index INTEGER NOT NULL,
        speaker_label TEXT NOT NULL,
        embedding TEXT NOT NULL DEFAULT '[]',
        created_at REAL,
        updated_at REAL,
        FOREIGN KEY(meeting_id) REFERENCES meetings(id),
        UNIQUE(meeting_id, unknown_index)
    );

    CREATE TABLE IF NOT EXISTS diarization_runs (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL,
        scope TEXT NOT NULL,
        status TEXT NOT NULL,
        audio_file_path TEXT NOT NULL,
        turns TEXT NOT NULL DEFAULT '[]',
        error_message TEXT,
        created_at REAL,
        FOREIGN KEY(meeting_id) REFERENCES meetings(id)
    );

    CREATE TABLE IF NOT EXISTS diarization_speaker_mappings (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL,
        speaker_key TEXT NOT NULL,
        speaker_label TEXT NOT NULL,
        person_id TEXT,
        person_name TEXT,
        confidence REAL NOT NULL DEFAULT 0,
        is_manual INTEGER NOT NULL DEFAULT 0,
        updated_at REAL,
        FOREIGN KEY(meeting_id) REFERENCES meetings(id),
        UNIQUE(meeting_id, speaker_key)
    );

    CREATE TABLE IF NOT EXISTS manual_overrides (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL,
        segment_id TEXT,
        override_type TEXT NOT NULL,
        before_value TEXT,
        after_value TEXT,
        created_at REAL,
        FOREIGN KEY(meeting_id) REFERENCES meetings(id),
        FOREIGN KEY(segment_id) REFERENCES transcript_segments(id)
    );

    CREATE TABLE IF NOT EXISTS export_jobs (
        id TEXT PRIMARY KEY,
        meeting_id TEXT NOT NULL,
        format TEXT NOT NULL,
        file_path TEXT,
        created_at REAL,
        FOREIGN KEY(meeting_id) REFERENCES meetings(id)
    );

    CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at REAL
    );
    """
}

public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    init(statement: OpaquePointer?, index: Int32) {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            self = .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            self = .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            self = .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            let count = sqlite3_column_bytes(statement, index)
            guard count > 0, let pointer = sqlite3_column_blob(statement, index) else {
                self = .blob(Data())
                return
            }
            self = .blob(Data(bytes: pointer, count: Int(count)))
        default:
            self = .null
        }
    }

    public var stringValue: String? {
        if case let .text(value) = self {
            return value
        }
        return nil
    }

    public var intValue: Int? {
        if case let .integer(value) = self {
            return Int(value)
        }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case let .real(value):
            return value
        case let .integer(value):
            return Double(value)
        default:
            return nil
        }
    }

    public var dataValue: Data? {
        if case let .blob(value) = self {
            return value
        }
        return nil
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
