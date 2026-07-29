import Foundation
import Testing
@testable import AItingjiCore

private enum TestAPIKeyStoreError: Error {
    case blocked
}

private struct UnavailableLegacyAPIKeyStore: ModelSourceAPIKeyStore {
    func apiKey(for reference: String) throws -> String? { throw TestAPIKeyStoreError.blocked }
    func setAPIKey(_ apiKey: String, for reference: String) throws { throw TestAPIKeyStoreError.blocked }
    func removeAPIKey(for reference: String) throws { throw TestAPIKeyStoreError.blocked }
}

@Test func modelSourceRepositoryStoresPlaintextAPIKeyInSQLiteWithoutKeychain() throws {
    let path = securityTestDatabasePath("plaintext")
    let database = try Database(path: path)
    try database.migrate()
    let repository = ModelSourceRepository(
        database: database,
        apiKeyStore: UnavailableLegacyAPIKeyStore()
    )
    let source = ModelSource(
        id: "plaintext-model",
        type: .asr,
        name: "本地模型服务",
        baseURL: "https://api.example.com/v1",
        apiKey: "sk-plain-local"
    )

    try repository.upsert(source)

    let row = try #require(database.query(
        "SELECT api_key, api_key_ref FROM model_sources WHERE id = ?",
        bindings: [.text(source.id)]
    ).first)
    #expect(row["api_key"]?.stringValue == "sk-plain-local")
    #expect(row["api_key_ref"]?.stringValue == nil)
    #expect(try repository.list().first?.apiKey == "sk-plain-local")

    try repository.delete(id: source.id)
    #expect(try repository.list().isEmpty)
    database.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func appPersistenceMigratesLegacyKeychainAPIKeyBackToSQLite() throws {
    let path = securityTestDatabasePath("keychain-to-plaintext")
    let database = try Database(path: path)
    try database.migrate()
    let sourceID = "legacy-keychain-model"
    let reference = ModelSourceRepository.apiKeyReference(for: sourceID)
    try database.execute(
        """
        INSERT INTO model_sources (
            id, type, name, base_url, api_key, api_key_ref,
            available_models, is_default, enabled
        )
        VALUES (?, ?, ?, ?, '', ?, '[]', 1, 1)
        """,
        bindings: [
            .text(sourceID),
            .text(ModelSourceType.asr.rawValue),
            .text("旧钥匙串模型"),
            .text("https://legacy.example.com/v1"),
            .text(reference)
        ]
    )
    database.close()
    let legacyStore = InMemoryModelSourceAPIKeyStore()
    try legacyStore.setAPIKey("sk-from-keychain", for: reference)

    let store = try AppPersistenceStore(path: path, apiKeyStore: legacyStore)
    let migrated = try #require(store.loadSnapshot().modelSources.first)
    #expect(migrated.apiKey == "sk-from-keychain")
    #expect(migrated.enabled)
    // 旧条目不主动删除，避免 SecItemDelete 再次触发钥匙串授权弹窗。
    #expect(try legacyStore.apiKey(for: reference) == "sk-from-keychain")
    store.close()

    let verifier = try Database(path: path)
    let row = try #require(verifier.query(
        "SELECT api_key, api_key_ref FROM model_sources WHERE id = ?",
        bindings: [.text(sourceID)]
    ).first)
    #expect(row["api_key"]?.stringValue == "sk-from-keychain")
    #expect(row["api_key_ref"]?.stringValue == nil)
    verifier.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func unreadableLegacyKeychainIsClearedAndDoesNotBlockFutureLaunches() throws {
    let path = securityTestDatabasePath("unreadable-keychain")
    let database = try Database(path: path)
    try database.migrate()
    let sourceID = "unreadable-keychain-model"
    try database.execute(
        """
        INSERT INTO model_sources (
            id, type, name, base_url, api_key, api_key_ref,
            available_models, is_default, enabled
        )
        VALUES (?, ?, ?, ?, '', ?, '[]', 1, 1)
        """,
        bindings: [
            .text(sourceID),
            .text(ModelSourceType.asr.rawValue),
            .text("无法迁移的旧模型"),
            .text("https://blocked.example.com/v1"),
            .text(ModelSourceRepository.apiKeyReference(for: sourceID))
        ]
    )
    database.close()

    let firstStore = try AppPersistenceStore(path: path, apiKeyStore: UnavailableLegacyAPIKeyStore())
    let degraded = try #require(firstStore.loadSnapshot().modelSources.first)
    #expect(degraded.apiKey.isEmpty)
    #expect(!degraded.enabled)
    #expect(degraded.lastTestMessage == "旧钥匙串密钥无法静默迁移，请重新录入一次")
    firstStore.close()

    // 引用已清空，后续启动即使完全无法访问钥匙串也不会再触发读取。
    let secondStore = try AppPersistenceStore(path: path, apiKeyStore: UnavailableLegacyAPIKeyStore())
    #expect(try secondStore.loadSnapshot().modelSources.first?.lastTestMessage == degraded.lastTestMessage)
    secondStore.close()

    let verifier = try Database(path: path)
    let row = try #require(verifier.query(
        "SELECT api_key_ref FROM model_sources WHERE id = ?",
        bindings: [.text(sourceID)]
    ).first)
    #expect(row["api_key_ref"]?.stringValue == nil)
    verifier.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func existingPlaintextKeyLoadsWhenKeychainIsUnavailable() throws {
    let path = securityTestDatabasePath("plaintext-without-keychain")
    let database = try Database(path: path)
    try database.migrate()
    try database.execute(
        """
        INSERT INTO model_sources (
            id, type, name, base_url, api_key, api_key_ref,
            available_models, is_default, enabled
        )
        VALUES (?, ?, ?, ?, ?, NULL, '[]', 1, 1)
        """,
        bindings: [
            .text("plain-model"),
            .text(ModelSourceType.postprocess.rawValue),
            .text("明文模型"),
            .text("https://plain.example.com/v1"),
            .text("test-readable-without-keychain")
        ]
    )
    database.close()

    let store = try AppPersistenceStore(path: path, apiKeyStore: UnavailableLegacyAPIKeyStore())
    let source = try #require(store.loadSnapshot().modelSources.first)
    #expect(source.apiKey == "test-readable-without-keychain")
    #expect(source.enabled)
    store.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func appPersistenceAvailabilityIsExplicitAfterClose() throws {
    let path = securityTestDatabasePath("availability")
    let store = try AppPersistenceStore(path: path, apiKeyStore: UnavailableLegacyAPIKeyStore())
    #expect(store.availability == .available)

    store.close()

    #expect(store.availability == .unavailable(.closed))
    #expect(throws: AppPersistenceStoreError.closed) {
        try store.setAppSetting("after_close", value: "must-fail")
    }
    try? FileManager.default.removeItem(atPath: path)
}

private func securityTestDatabasePath(_ name: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-tingji-security-\(UUID().uuidString)-\(name).sqlite")
        .path
}
