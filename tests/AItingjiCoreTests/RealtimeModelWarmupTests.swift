import AItingjiCore
import Testing

@Test
func realtimeModelWarmupRequiresASRAndVoiceprintSources() throws {
    let voiceprint = ModelSource(
        id: "voiceprint",
        type: .voiceprint,
        name: "内置声纹",
        baseURL: "builtin://voiceprint",
        selectedModel: "builtin-voiceprint-v2"
    )

    #expect(throws: RealtimeModelWarmupError.missingASR) {
        _ = try RealtimeModelWarmupPreflight.validate(asr: nil, voiceprint: voiceprint)
    }
}

@Test
func realtimeModelWarmupRejectsExampleASRSource() throws {
    let asr = ModelSource(
        id: "asr",
        type: .asr,
        name: "示例转写",
        baseURL: "https://api.example.com/v1",
        selectedModel: "whisper-large-v3"
    )
    let voiceprint = ModelSource(
        id: "voiceprint",
        type: .voiceprint,
        name: "内置声纹",
        baseURL: "builtin://voiceprint",
        selectedModel: "builtin-voiceprint-v2"
    )

    #expect(throws: RealtimeModelWarmupError.invalidASRBaseURL) {
        _ = try RealtimeModelWarmupPreflight.validate(asr: asr, voiceprint: voiceprint)
    }
}

@Test
func realtimeModelWarmupAcceptsConfiguredASRAndBuiltInVoiceprint() throws {
    let asr = ModelSource(
        id: "asr",
        type: .asr,
        name: "本地转写",
        baseURL: "http://127.0.0.1:18001/v1",
        selectedModel: "Qwen3-ASR-1.7B-8bit"
    )
    let voiceprint = ModelSource(
        id: "voiceprint",
        type: .voiceprint,
        name: "内置声纹",
        baseURL: "builtin://voiceprint",
        selectedModel: "builtin-voiceprint-v2"
    )

    let sources = try RealtimeModelWarmupPreflight.validate(asr: asr, voiceprint: voiceprint)

    #expect(sources.asr.id == "asr")
    #expect(sources.voiceprint.id == "voiceprint")
}

@Test
func realtimeASRWarmupDoesNotRequireVoiceprintSource() throws {
    let asr = ModelSource(
        id: "asr",
        type: .asr,
        name: "本地转写",
        baseURL: "http://127.0.0.1:18001/v1",
        selectedModel: "Qwen3-ASR-1.7B-8bit"
    )

    let source = try RealtimeASRWarmupPreflight.validate(asr: asr)

    #expect(source.id == "asr")
}

@Test
func realtimeASRWarmupRejectsExampleASRSource() throws {
    let asr = ModelSource(
        id: "asr",
        type: .asr,
        name: "示例转写",
        baseURL: "https://api.example.com/v1",
        selectedModel: "whisper-large-v3"
    )

    #expect(throws: RealtimeModelWarmupError.invalidASRBaseURL) {
        _ = try RealtimeASRWarmupPreflight.validate(asr: asr)
    }
}
