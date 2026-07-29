import AItingjiCore
import Testing

@Test
func diarizationTokenResolverPrefersVoiceprintSourceAPIKey() {
    let source = ModelSource(
        id: "voiceprint",
        type: .voiceprint,
        name: "本机说话人分离",
        baseURL: "sidecar://diarization",
        apiKey: " hf-from-page "
    )

    let token = DiarizationTokenResolver.resolve(
        source: source,
        environment: ["HF_TOKEN": "hf-from-env"]
    )

    #expect(token == "hf-from-page")
}

@Test
func diarizationTokenResolverFallsBackToEnvironment() {
    let source = ModelSource(
        id: "voiceprint",
        type: .voiceprint,
        name: "本机说话人分离",
        baseURL: "sidecar://diarization",
        apiKey: "  "
    )

    let token = DiarizationTokenResolver.resolve(
        source: source,
        environment: ["HUGGINGFACE_TOKEN": "hf-from-env"]
    )

    #expect(token == "hf-from-env")
}

@Test
func diarizationTokenResolverReturnsNilWhenNoTokenExists() {
    let token = DiarizationTokenResolver.resolve(source: nil, environment: [:])

    #expect(token == nil)
}
