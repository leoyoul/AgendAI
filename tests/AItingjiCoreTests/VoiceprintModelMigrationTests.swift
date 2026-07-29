import AItingjiCore
import Testing

@Test
func voiceprintModelMigrationRestoresBundledSidecarWhenMissing() {
    let restored = VoiceprintModelMigration.restoreBundledSidecar([])

    #expect(restored.count == 1)
    #expect(restored[0].id == VoiceprintModelMigration.bundledSidecarID)
    #expect(restored[0].baseURL == "sidecar://diarization")
    #expect(restored[0].selectedModel == VoiceprintModelMigration.sidecarModel)
    #expect(restored[0].enabled)
    #expect(restored[0].isDefault)
}

@Test
func voiceprintModelMigrationDoesNotDuplicateBundledSidecar() {
    let source = ModelSource(
        id: "existing",
        type: .voiceprint,
        name: "本机声纹",
        baseURL: "sidecar://diarization",
        selectedModel: VoiceprintModelMigration.sidecarModel,
        isDefault: true
    )

    let restored = VoiceprintModelMigration.restoreBundledSidecar([source])

    #expect(restored.count == 1)
    #expect(restored[0].id == "existing")
}

@Test
func oldDefaultBuiltInVoiceprintMigratesToDiarizationSidecar() {
    let sources = [
        ModelSource(
            id: "model-voiceprint",
            type: .voiceprint,
            name: "内置声纹模型",
            baseURL: "builtin://voiceprint",
            selectedModel: "builtin-voiceprint-v2",
            availableModels: ["builtin-voiceprint-v2"],
            isDefault: true
        )
    ]

    let migrated = VoiceprintModelMigration.migrateDefaultBuiltInToDiarization(sources)

    #expect(migrated[0].name == "本机说话人分离")
    #expect(migrated[0].baseURL == "sidecar://diarization")
    #expect(migrated[0].selectedModel == VoiceprintModelMigration.sidecarModel)
    #expect(migrated[0].availableModels == [VoiceprintModelMigration.sidecarModel])
    #expect(migrated[0].isDefault)
}

@Test
func oldDiarizationSidecarModelMigratesToFunASR() {
    let sources = [
        ModelSource(
            id: "model-voiceprint",
            type: .voiceprint,
            name: "本机说话人分离",
            baseURL: "sidecar://diarization",
            selectedModel: "pyannote-community-1+speechbrain-ecapa",
            availableModels: ["pyannote-community-1+speechbrain-ecapa"],
            isDefault: true,
            lastTestOK: true,
            lastTestMessage: "旧测试结果"
        )
    ]

    let migrated = VoiceprintModelMigration.migrateSidecarModelToFunASR(sources)

    #expect(migrated[0].selectedModel == VoiceprintModelMigration.sidecarModel)
    #expect(migrated[0].availableModels == [VoiceprintModelMigration.sidecarModel])
    #expect(migrated[0].lastTestOK == nil)
    #expect(migrated[0].lastTestMessage == nil)
}

@Test
func externalDefaultVoiceprintSourceIsNotOverwrittenByMigration() {
    let sources = [
        ModelSource(
            id: "external-voiceprint",
            type: .voiceprint,
            name: "外部声纹服务",
            baseURL: "https://voiceprint.example.test/v1",
            selectedModel: "vendor-speaker-v1",
            isDefault: true
        ),
        ModelSource(
            id: "model-voiceprint",
            type: .voiceprint,
            name: "内置声纹模型",
            baseURL: "builtin://voiceprint",
            selectedModel: "builtin-voiceprint-v2",
            isDefault: false
        )
    ]

    let migrated = VoiceprintModelMigration.migrateDefaultBuiltInToDiarization(sources)

    #expect(migrated[0].baseURL == "https://voiceprint.example.test/v1")
    #expect(migrated[0].isDefault)
    #expect(migrated[1].baseURL == "builtin://voiceprint")
    #expect(!migrated[1].isDefault)
}

@Test
func staleDiarizationConfigOnlyTestResultIsCleared() {
    let sources = [
        ModelSource(
            id: "model-voiceprint",
            type: .voiceprint,
            name: "本机说话人分离",
            baseURL: "sidecar://diarization",
            selectedModel: "pyannote-community-1+speechbrain-ecapa",
            isDefault: true,
            lastTestOK: true,
            lastTestMessage: "本机说话人分离 sidecar 可配置，首次真实模型加载需要 Hugging Face token。"
        )
    ]

    let migrated = VoiceprintModelMigration.clearStaleDiarizationTestResult(sources)

    #expect(migrated[0].lastTestOK == nil)
    #expect(migrated[0].lastTestMessage == nil)
    #expect(migrated[0].lastTestAt == nil)
}
