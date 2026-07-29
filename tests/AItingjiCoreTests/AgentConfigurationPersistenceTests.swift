import AItingjiCore
import Foundation
import Testing

@Test
func agentModelAndDifyConfigurationPersistAcrossDatabaseReopen() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("AItingji-agent-config-\(UUID().uuidString).sqlite")
    let source = ModelSource(
        id: "agent-model-1",
        type: .agent,
        name: "会议 Agent",
        baseURL: "https://agent.example.test/v1",
        apiKey: "agent-key",
        apiProtocol: .responses,
        selectedModel: "agent-model",
        availableModels: ["agent-model"],
        isDefault: true,
        enabled: true
    )
    let configuration = DifyKnowledgeBaseConfiguration(
        baseURL: "https://dify.example.test/v1",
        apiKey: "dataset-key",
        enabled: true,
        knowledgeBases: [DifyKnowledgeBase(id: "kb-1", name: "产品库")],
        selectedKnowledgeBaseIDs: ["kb-1"]
    )
    let configurationJSON = String(
        decoding: try JSONEncoder().encode(configuration),
        as: UTF8.self
    )

    do {
        let store = try AppPersistenceStore(path: url.path)
        try store.upsertModelSource(source)
        try store.setAppSetting(
            AppSettingKey.difyKnowledgeBaseConfiguration,
            value: configurationJSON
        )
        store.close()
    }

    let reopened = try AppPersistenceStore(path: url.path)
    defer {
        reopened.close()
        try? FileManager.default.removeItem(at: url)
    }
    let snapshot = try reopened.loadSnapshot()
    #expect(snapshot.modelSources == [source])
    let restoredJSON = try #require(snapshot.appSettings[AppSettingKey.difyKnowledgeBaseConfiguration])
    let restored = try JSONDecoder().decode(
        DifyKnowledgeBaseConfiguration.self,
        from: Data(restoredJSON.utf8)
    )
    #expect(restored == configuration)
}
