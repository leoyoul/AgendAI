import Foundation
import Testing
@testable import AItingjiCore

final class InMemoryModelSourceAPIKeyStore: @unchecked Sendable, ModelSourceAPIKeyStore {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func apiKey(for reference: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[reference]
    }

    func setAPIKey(_ apiKey: String, for reference: String) throws {
        lock.lock()
        values[reference] = apiKey
        lock.unlock()
    }

    func removeAPIKey(for reference: String) throws {
        lock.lock()
        values.removeValue(forKey: reference)
        lock.unlock()
    }
}

@Test func modelSourceRepositoryPersistsAvailableModelsAndTestResult() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-tingji-model-source-\(UUID().uuidString).sqlite")
        .path
    let database = try Database(path: path)
    try database.migrate()
    let repository = ModelSourceRepository(database: database, apiKeyStore: InMemoryModelSourceAPIKeyStore())
    let testedAt = Date(timeIntervalSince1970: 1_800_000_000)

    try repository.upsert(
        ModelSource(
            id: "model-config",
            type: .meetingMinutes,
            name: "可测试模型服务",
            baseURL: "mock://models",
            apiKey: "sk-test",
            apiProtocol: .responses,
            selectedModel: "asr-small",
            availableModels: ["asr-small", "asr-large"],
            isDefault: true,
            enabled: true,
            meetingMinutesMaximumConcurrency: 4,
            lastTestOK: true,
            lastTestMessage: "连接成功",
            lastTestAt: testedAt
        )
    )

    let saved = try #require(repository.list().first)
    #expect(saved.availableModels == ["asr-small", "asr-large"])
    #expect(saved.apiProtocol == .responses)
    #expect(saved.meetingMinutesMaximumConcurrency == 4)
    #expect(saved.lastTestOK == true)
    #expect(saved.lastTestMessage == "连接成功")
    #expect(saved.lastTestAt == testedAt)
    database.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func modelSourceRepositoryPersistsUnlimitedMeetingMinutesConcurrency() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-tingji-model-unlimited-\(UUID().uuidString).sqlite")
        .path
    let database = try Database(path: path)
    try database.migrate()
    let repository = ModelSourceRepository(database: database, apiKeyStore: InMemoryModelSourceAPIKeyStore())

    try repository.upsert(ModelSource(
        id: "unlimited-minutes",
        type: .meetingMinutes,
        name: "云端会议纪要",
        baseURL: "https://example.test/v1",
        selectedModel: "cloud-model",
        meetingMinutesMaximumConcurrency: nil
    ))

    #expect(try repository.list().first?.meetingMinutesMaximumConcurrency == nil)
    database.close()
    try? FileManager.default.removeItem(atPath: path)
}

@Test func modelSourceCodablePreservesUnlimitedAndDefaultsLegacyConcurrency() throws {
    let unlimited = ModelSource(
        id: "unlimited-codable",
        type: .meetingMinutes,
        name: "云端模型",
        baseURL: "https://example.test/v1",
        meetingMinutesMaximumConcurrency: nil
    )
    let encoded = try JSONEncoder().encode(unlimited)
    let decoded = try JSONDecoder().decode(ModelSource.self, from: encoded)
    #expect(decoded.meetingMinutesMaximumConcurrency == nil)

    var legacyObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacyObject.removeValue(forKey: "meetingMinutesMaximumConcurrency")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    let legacy = try JSONDecoder().decode(ModelSource.self, from: legacyData)
    #expect(legacy.meetingMinutesMaximumConcurrency == 1)
}

@Test func modelSourceRepositoryDeletesSource() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("ai-tingji-model-source-delete-\(UUID().uuidString).sqlite")
        .path
    let database = try Database(path: path)
    try database.migrate()
    let repository = ModelSourceRepository(database: database, apiKeyStore: InMemoryModelSourceAPIKeyStore())

    try repository.upsert(
        ModelSource(
            id: "delete-me",
            type: .asr,
            name: "待删除模型服务",
            baseURL: "mock://asr",
            selectedModel: "mock-asr",
            isDefault: true,
            enabled: true
        )
    )
    try repository.upsert(
        ModelSource(
            id: "keep-me",
            type: .asr,
            name: "保留模型服务",
            baseURL: "mock://asr2",
            selectedModel: "mock-asr2",
            enabled: true
        )
    )

    try repository.delete(id: "delete-me")

    let saved = try repository.list()
    #expect(saved.map(\.id) == ["keep-me"])
    database.close()
    try? FileManager.default.removeItem(atPath: path)
}
