import Foundation
import SQLite3
import Testing
@testable import AItingjiCore

@Suite("App persistence upgrade backups", .serialized)
struct AppPersistenceStoreUpgradeBackupTests {
    @Test("backs up an existing database before a new app version opens it")
    func backupRetainsMeetingAccountSettingsAndAPIKey() throws {
        let fixture = try UpgradeBackupFixture()
        defer { fixture.remove() }

        let firstStore = try fixture.open(version: "0.1.1 (2)")
        try firstStore.upsertMeeting(Meeting(
            id: "upgrade-meeting",
            title: "升级前会议",
            status: .draft,
            captureSource: .microphone,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try firstStore.upsertSegment(TranscriptSegment(
            id: "upgrade-segment",
            meetingID: "upgrade-meeting",
            startMs: 0,
            endMs: 1_000,
            speakerLabel: "李四",
            rawText: "这段转写必须在升级后保留"
        ))
        try firstStore.upsertMeetingNote(MeetingNote(
            id: "upgrade-note",
            meetingID: "upgrade-meeting",
            body: "这条人工纪要必须在升级后保留"
        ))
        try firstStore.upsertPerson(VoiceprintPerson(
            id: "upgrade-person",
            displayName: "李四",
            zentaoAccount: "lisi"
        ))
        try firstStore.upsertModelSource(ModelSource(
            id: "upgrade-model",
            type: .agent,
            name: "升级模型",
            baseURL: "https://example.invalid/v1",
            apiKey: "preserved-api-key",
            selectedModel: "model-before-upgrade"
        ))
        try firstStore.setAppSetting(AppSettingKey.currentUserPersonID, value: "upgrade-person")
        firstStore.close()

        let upgradedStore = try fixture.open(version: "0.1.2 (3)")
        upgradedStore.close()

        let backupURL = try #require(fixture.backups().first)
        let inspectedBackup = try AppPersistenceStore(
            path: backupURL.path,
            apiKeyStore: UpgradeBackupTestAPIKeyStore(),
            appVersion: "backup-inspection",
            upgradeBackupDirectory: fixture.root.appendingPathComponent("backup-inspection")
        )
        let backupSnapshot = try inspectedBackup.loadSnapshot()
        inspectedBackup.close()
        #expect(backupSnapshot.meetings.map(\.id) == ["upgrade-meeting"])
        #expect(backupSnapshot.segmentsByMeeting["upgrade-meeting"]?.first?.rawText == "这段转写必须在升级后保留")
        #expect(backupSnapshot.notesByMeeting["upgrade-meeting"]?.first?.body == "这条人工纪要必须在升级后保留")
        #expect(backupSnapshot.people.first?.zentaoAccount == "lisi")
        #expect(backupSnapshot.modelSources.first?.apiKey == "preserved-api-key")
        #expect(backupSnapshot.appSettings[AppSettingKey.currentUserPersonID] == "upgrade-person")

        let backupPermissions = try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions] as? NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: fixture.backupDirectory.path)[.posixPermissions] as? NSNumber
        #expect((backupPermissions?.intValue ?? 0) & 0o077 == 0)
        #expect((directoryPermissions?.intValue ?? 0) & 0o077 == 0)
    }

    @Test("does not repeat a backup for the same app version and retains only three")
    func avoidsDuplicateBackupsAndPrunesOldBackups() throws {
        let fixture = try UpgradeBackupFixture()
        defer { fixture.remove() }

        let initial = try fixture.open(version: "0.1.1 (2)")
        initial.close()

        let versionTwo = try fixture.open(version: "0.1.2 (3)")
        versionTwo.close()
        #expect(fixture.backups().count == 1)

        let versionTwoAgain = try fixture.open(version: "0.1.2 (3)")
        versionTwoAgain.close()
        #expect(fixture.backups().count == 1)

        for version in ["0.1.3 (4)", "0.1.4 (5)", "0.1.5 (6)"] {
            let store = try fixture.open(version: version)
            store.close()
        }
        #expect(fixture.backups().count == 3)
    }

    @Test("a backup failure prevents database migration")
    func backupFailureStopsMigration() throws {
        let fixture = try UpgradeBackupFixture()
        defer { fixture.remove() }
        try createLegacyDatabase(at: fixture.databaseURL)

        #expect(throws: AppPersistenceStoreError.self) {
            try AppPersistenceStore(
                path: fixture.databaseURL.path,
                apiKeyStore: UpgradeBackupTestAPIKeyStore(),
                appVersion: "0.1.2 (3)",
                upgradeBackupDirectory: fixture.backupDirectory,
                upgradeBackupOperation: { _, _ in throw UpgradeBackupTestError.forcedFailure }
            )
        }
        #expect(sqliteString(
            at: fixture.databaseURL,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'app_settings'"
        ) == nil)
    }

    @Test("custom test database backups stay inside the custom data root")
    func customDatabasePathDoesNotUseProductionDataRoot() throws {
        let fixture = try UpgradeBackupFixture()
        defer { fixture.remove() }

        let initial = try fixture.open(version: "0.1.1 (2)")
        initial.close()
        let upgraded = try fixture.open(version: "0.1.2 (3)")
        upgraded.close()

        #expect(fixture.backupDirectory.standardizedFileURL.path.hasPrefix(fixture.root.standardizedFileURL.path))
        #expect(!fixture.backupDirectory.standardizedFileURL.path.hasPrefix(ApplicationDataDirectory.rootURL.standardizedFileURL.path))
        #expect(fixture.backups().allSatisfy {
            $0.deletingLastPathComponent().standardizedFileURL == fixture.backupDirectory.standardizedFileURL
        })
    }
}

private final class UpgradeBackupFixture {
    let root: URL
    let databaseURL: URL
    let backupDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ai-tingji-upgrade-backup-\(UUID().uuidString)", isDirectory: true)
        databaseURL = root.appendingPathComponent("ai-tingji.sqlite")
        backupDirectory = UpgradeBackup.defaultDirectory(for: databaseURL)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func open(version: String) throws -> AppPersistenceStore {
        try AppPersistenceStore(
            path: databaseURL.path,
            apiKeyStore: UpgradeBackupTestAPIKeyStore(),
            appVersion: version,
            upgradeBackupDirectory: backupDirectory
        )
    }

    func backups() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
        .filter { $0.pathExtension == "sqlite" && $0.lastPathComponent.hasPrefix("ai-tingji-before-") }
        ?? []
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum UpgradeBackupTestError: LocalizedError {
    case forcedFailure

    var errorDescription: String? { "forced backup failure" }
}

private final class UpgradeBackupTestAPIKeyStore: @unchecked Sendable, ModelSourceAPIKeyStore {
    func apiKey(for reference: String) throws -> String? { nil }
    func setAPIKey(_ apiKey: String, for reference: String) throws {}
    func removeAPIKey(for reference: String) throws {}
}

private func createLegacyDatabase(at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let database
    else {
        defer { if let database { sqlite3_close_v2(database) } }
        throw UpgradeBackupTestError.forcedFailure
    }
    defer { sqlite3_close_v2(database) }
    guard sqlite3_exec(database, "CREATE TABLE legacy_only (id TEXT);", nil, nil, nil) == SQLITE_OK else {
        throw UpgradeBackupTestError.forcedFailure
    }
}

private func sqliteString(at url: URL, sql: String) -> String? {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          let database
    else {
        if let database { sqlite3_close_v2(database) }
        return nil
    }
    defer { sqlite3_close_v2(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          let statement
    else {
        if let statement { sqlite3_finalize(statement) }
        return nil
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
          let value = sqlite3_column_text(statement, 0)
    else {
        return nil
    }
    return String(cString: value)
}
