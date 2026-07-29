import AItingjiCore
import Foundation
import Testing

@Test
func databaseCreatesRequiredTables() throws {
    let path = temporaryDatabasePath("schema")
    let database = try Database(path: path)
    try database.migrate()

    let rows = try database.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
    )
    let tableNames = Set(rows.compactMap { $0["name"]?.stringValue })

    #expect(tableNames.contains("model_sources"))
    #expect(tableNames.contains("meetings"))
    #expect(tableNames.contains("transcript_segments"))
    #expect(tableNames.contains("people"))
    #expect(tableNames.contains("terminology_entries"))
    #expect(tableNames.contains("voiceprint_samples"))
    #expect(tableNames.contains("meeting_unknown_speakers"))
    #expect(tableNames.contains("manual_overrides"))
    #expect(tableNames.contains("export_jobs"))
    #expect(tableNames.contains("app_settings"))
}

@Test
func databaseMigratesLegacyModelSourcesToChatCompletionsProtocol() throws {
    let path = temporaryDatabasePath("legacy-model-api-protocol")
    let database = try Database(path: path)
    try database.execute(
        """
        CREATE TABLE model_sources (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            name TEXT NOT NULL,
            base_url TEXT NOT NULL,
            api_key TEXT NOT NULL DEFAULT '',
            api_key_ref TEXT,
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
        INSERT INTO model_sources (id, type, name, base_url)
        VALUES ('legacy-gpt', 'meeting_minutes', '旧 GPT', 'https://api.openai.com/v1');
        """
    )

    try database.migrate()

    let row = try #require(
        database.query(
            "SELECT api_protocol, meeting_minutes_max_concurrency FROM model_sources WHERE id = 'legacy-gpt'"
        ).first
    )
    #expect(row["api_protocol"]?.stringValue == ModelAPIProtocol.chatCompletions.rawValue)
    #expect(row["meeting_minutes_max_concurrency"]?.intValue == 1)
}

@Test
func meetingPersistsAfterDatabaseReopen() throws {
    let path = temporaryDatabasePath("meeting-reopen")
    var database: Database? = try Database(path: path)
    try database?.migrate()
    let meeting = Meeting(
        id: "m1",
        title: "周会",
        captureSource: .screenAudio,
        createdAt: Date(timeIntervalSince1970: 1_800)
    )
    try MeetingRepository(database: database!).create(meeting)
    database?.close()
    database = nil

    let reopened = try Database(path: path)
    try reopened.migrate()
    let loaded = try MeetingRepository(database: reopened).get(id: "m1")

    #expect(loaded.title == "周会")
    #expect(loaded.captureSource == .screenAudio)
}

@Test
func repositoriesWriteAndReadCoreRecords() throws {
    let path = temporaryDatabasePath("repositories")
    let database = try Database(path: path)
    try database.migrate()

    let meeting = Meeting(
        id: "m1",
        title: "需求会",
        createdAt: Date(timeIntervalSince1970: 2_000)
    )
    try MeetingRepository(database: database).create(meeting)

    try SegmentRepository(database: database).create(
        TranscriptSegment(
            id: "s1",
            meetingID: "m1",
            startMs: 0,
            endMs: 1200,
            speakerLabel: "未知发言人 1",
            rawText: "先说一下需求",
            finalText: "先说一下需求"
        )
    )

    try PeopleRepository(database: database).create(
        VoiceprintPerson(
            id: "p1",
            displayName: "张三",
            aliases: ["老张"],
            jobTitle: "项目经理",
            roleTags: ["项目", "交付"],
            responsibilities: "统筹项目计划、协调交付并跟踪风险",
            zentaoAccount: "zhangsan",
            zentaoUserID: "18"
        )
    )

    try TerminologyRepository(database: database).upsert(
        TerminologyEntry(
            id: "term1",
            canonicalName: "示例科技",
            aliases: ["示例", "ExampleTech"],
            category: "公司"
        )
    )

    try ModelSourceRepository(database: database).create(
        ModelSource(
            id: "model1",
            type: .asr,
            name: "Mock ASR",
            baseURL: "mock://asr",
            selectedModel: "mock-model",
            isDefault: true
        )
    )

    let segments = try SegmentRepository(database: database).list(meetingID: "m1")
    let people = try PeopleRepository(database: database).list()
    let terminology = try TerminologyRepository(database: database).list()
    let models = try ModelSourceRepository(database: database).list()

    #expect(segments.first?.speakerLabel == "未知发言人 1")
    #expect(people.first?.displayName == "张三")
    #expect(people.first?.aliases == ["老张"])
    #expect(people.first?.jobTitle == "项目经理")
    #expect(people.first?.roleTags == ["项目", "交付"])
    #expect(people.first?.responsibilities == "统筹项目计划、协调交付并跟踪风险")
    #expect(people.first?.zentaoAccount == "zhangsan")
    #expect(people.first?.zentaoUserID == "18")
    #expect(terminology.first?.canonicalName == "示例科技")
    #expect(terminology.first?.aliases == ["示例", "ExampleTech"])
    #expect(models.first?.name == "Mock ASR")
    #expect(models.first?.isDefault == true)
}

@Test
func peopleRepositoryListsNewestFirstAndEditingDoesNotReorder() throws {
    let path = temporaryDatabasePath("people-created-order")
    let database = try Database(path: path)
    try database.migrate()
    defer {
        database.close()
        try? FileManager.default.removeItem(atPath: path)
    }
    let repository = PeopleRepository(database: database)
    let older = VoiceprintPerson(id: "person-older", displayName: "较早添加")
    let newer = VoiceprintPerson(id: "person-newer", displayName: "较晚添加")

    try repository.create(older)
    try repository.create(newer)
    #expect(try repository.list().map(\.id) == [newer.id, older.id])

    var renamedOlder = older
    renamedOlder.displayName = "编辑后的较早人员"
    renamedOlder.responsibilities = "负责维护项目计划"
    try repository.upsert(renamedOlder)
    #expect(try repository.list().map(\.id) == [newer.id, older.id])
    #expect(try repository.list().first(where: { $0.id == older.id })?.responsibilities == "负责维护项目计划")

    let creationRows = try database.query(
        "SELECT created_at FROM people WHERE created_at IS NOT NULL"
    )
    #expect(creationRows.count == 2)
}

@Test
func legacyPeopleGainEmptyResponsibilitiesDuringMigration() throws {
    let path = temporaryDatabasePath("legacy-people-responsibilities")
    let database = try Database(path: path)
    try database.migrate()
    defer {
        database.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    try database.execute("ALTER TABLE people DROP COLUMN responsibilities")
    try database.execute(
        """
        INSERT INTO people (id, display_name, aliases, job_title, role_tags, threshold, is_active)
        VALUES ('legacy-person', '旧人员', '[]', '项目经理', '["项目"]', 0.95, 1)
        """
    )

    try database.migrate()

    let person = try #require(try PeopleRepository(database: database).list().first)
    #expect(person.id == "legacy-person")
    #expect(person.responsibilities.isEmpty)
}

@Test
func configurationRepositoriesDeleteTermsAndPeopleWithVoiceprintSamples() throws {
    let path = temporaryDatabasePath("configuration-delete")
    let database = try Database(path: path)
    try database.migrate()
    defer {
        database.close()
        try? FileManager.default.removeItem(atPath: path)
    }
    let people = PeopleRepository(database: database)
    let samples = VoiceprintSampleRepository(database: database)
    let terminology = TerminologyRepository(database: database)
    try people.create(VoiceprintPerson(id: "person-delete", displayName: "待删除人员"))
    try samples.upsert(VoiceprintSample(
        id: "sample-delete",
        personID: "person-delete",
        embedding: [1, 0, 0]
    ))
    try terminology.upsert(TerminologyEntry(
        id: "term-delete",
        canonicalName: "待删除词条",
        aliases: ["旧称"]
    ))

    try people.delete(id: "person-delete")
    try terminology.delete(id: "term-delete")

    #expect(try people.list().isEmpty)
    #expect(try samples.list().isEmpty)
    #expect(try terminology.list().isEmpty)
}

private func temporaryDatabasePath(_ name: String) -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AItingji-\(UUID().uuidString)-\(name)")
        .appendingPathExtension("sqlite")
    return url.path
}
