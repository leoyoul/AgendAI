import AItingjiCore
import Foundation
import Testing

@Test
func mockModelSourceTestReturnsSelectedModel() async {
    let source = ModelSource(
        id: "m1",
        type: .asr,
        name: "Mock ASR",
        baseURL: "mock://asr",
        selectedModel: "mock-asr"
    )

    let result = await ModelSourceTester(loader: MockHTTPDataLoader()).test(source: source)

    #expect(result.ok)
    #expect(result.models == ["mock-asr"])
}

@Test
func modelSourceTesterParsesOpenAICompatibleModels() async {
    let source = ModelSource(
        id: "m1",
        type: .asr,
        name: "Local ASR",
        baseURL: "https://example.test/v1",
        apiKey: "key"
    )
    let loader = MockHTTPDataLoader(
        data: #"{"data":[{"id":"asr-large"},{"id":"asr-small"}]}"#.data(using: .utf8)!
    )

    let result = await ModelSourceTester(loader: loader).test(source: source)

    #expect(result.ok)
    #expect(result.models == ["asr-large", "asr-small"])
}

@Test
func modelSourceTesterSurfacesOpenAIAuthenticationError() async {
    let source = ModelSource(
        id: "gpt",
        type: .meetingMinutes,
        name: "GPT",
        baseURL: "https://api.openai.com/v1",
        apiKey: "invalid-key",
        apiProtocol: .responses
    )
    let loader = MockHTTPDataLoader(
        data: #"{"error":{"message":"Incorrect API key provided"}}"#.data(using: .utf8)!,
        statusCode: 401
    )

    let result = await ModelSourceTester(loader: loader).test(source: source)

    #expect(!result.ok)
    #expect(result.message == "服务返回 401：Incorrect API key provided")
}

@Test
func modelSourceTesterRecognizesBuiltInVoiceprintSource() async {
    let source = ModelSource(
        id: "builtin-voiceprint",
        type: .voiceprint,
        name: "内置声纹",
        baseURL: "builtin://voiceprint",
        selectedModel: "builtin-voiceprint-v2"
    )

    let result = await ModelSourceTester(loader: MockHTTPDataLoader()).test(source: source)

    #expect(result.ok)
    #expect(result.message == "内置声纹模型可用")
    #expect(result.models == ["builtin-voiceprint-v2"])
}

@Test
func modelSourceTesterRecognizesDiarizationSidecarSource() async {
    let source = ModelSource(
        id: "diarization-sidecar",
        type: .voiceprint,
        name: "本机说话人分离",
        baseURL: "sidecar://diarization",
        selectedModel: VoiceprintModelMigration.sidecarModel
    )

    let result = await ModelSourceTester(loader: MockHTTPDataLoader()).test(source: source)

    #expect(result.ok)
    #expect(result.models == [VoiceprintModelMigration.sidecarModel])
}

@Test
func mockModelClientsReturnDeterministicResults() async throws {
    let chunk = AudioChunk(
        sequence: 0,
        startMs: 0,
        endMs: 1000,
        samples: [0.1],
        format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
    )

    let asr = try await MockASRClient(text: "测试文本").transcribe(chunk: chunk)
    let voiceprint = try await MockVoiceprintClient(embedding: [0, 1, 0]).identify(chunk: chunk)
    let polished = try await MockPostprocessClient().polish(text: asr.text)

    #expect(asr.text == "测试文本")
    #expect(voiceprint.embedding == [0, 1, 0])
    #expect(polished == "测试文本。")
}

@Test
func builtInVoiceprintClientCreatesStableNormalizedEmbedding() async throws {
    let client = BuiltInVoiceprintClient()
    let firstChunk = AudioChunk(
        sequence: 1,
        startMs: 0,
        endMs: 1_000,
        samples: [0.0, 0.15, -0.2, 0.3, -0.1, 0.05],
        format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
    )
    let sameChunk = AudioChunk(
        sequence: 2,
        startMs: 2_000,
        endMs: 3_000,
        samples: firstChunk.samples,
        format: firstChunk.format
    )
    let differentChunk = AudioChunk(
        sequence: 3,
        startMs: 4_000,
        endMs: 5_000,
        samples: [0.0, -0.4, 0.2, -0.1, 0.05, 0.3],
        format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
    )

    let first = try await client.identify(chunk: firstChunk)
    let same = try await client.identify(chunk: sameChunk)
    let different = try await client.identify(chunk: differentChunk)
    let norm = sqrt(first.embedding.reduce(0) { $0 + $1 * $1 })

    #expect(first.embedding.count == 64)
    #expect(abs(norm - 1) < 0.000001)
    #expect(first.confidence > 0)
    #expect(first.embedding == same.embedding)
    #expect(first.embedding != different.embedding)
}

@Test
func builtInVoiceprintClientReturnsZeroConfidenceForSilentAudio() async throws {
    let chunk = AudioChunk(
        sequence: 1,
        startMs: 0,
        endMs: 1_000,
        samples: Array(repeating: 0, count: 16_000),
        format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
    )

    let result = try await BuiltInVoiceprintClient().identify(chunk: chunk)

    #expect(result.embedding.count == 64)
    #expect(result.confidence == 0)
}

@Test
func openAICompatibleASRClientUploadsWAVAndParsesText() async throws {
    let source = ModelSource(
        id: "asr-openai",
        type: .asr,
        name: "OpenAI ASR",
        baseURL: "https://asr.example.test/v1/",
        apiKey: "secret",
        selectedModel: "gpt-4o-transcribe"
    )
    let uploader = RecordingHTTPUploader(
        response: HTTPUploadResponse(
            data: #"{"text":"这是接口返回的转写"}"#.data(using: .utf8)!,
            statusCode: 200
        )
    )
    let client = OpenAICompatibleASRClient(source: source, uploader: uploader)
    let chunk = AudioChunk(
        sequence: 7,
        startMs: 2_000,
        endMs: 3_500,
        samples: [0.0, 0.1, -0.1, 0.0],
        format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
    )

    let segment = try await client.transcribe(chunk: chunk)
    let request = try await #require(uploader.recordedRequest())
    let bodyText = String(decoding: request.body, as: UTF8.self)

    #expect(segment.startMs == 2_000)
    #expect(segment.endMs == 3_500)
    #expect(segment.text == "这是接口返回的转写")
    #expect(request.url.absoluteString == "https://asr.example.test/v1/audio/transcriptions")
    #expect(request.headers["Authorization"] == "Bearer secret")
    #expect(request.headers["Content-Type"]?.contains("multipart/form-data; boundary=") == true)
    #expect(bodyText.contains(#"name="model""#))
    #expect(bodyText.contains("gpt-4o-transcribe"))
    #expect(bodyText.contains(#"name="language""#))
    #expect(bodyText.contains("zh"))
    #expect(bodyText.contains(#"name="temperature""#))
    #expect(bodyText.contains("0"))
    #expect(bodyText.contains(#"name="response_format""#))
    #expect(bodyText.contains("json"))
    #expect(bodyText.contains(#"filename="chunk-7.wav""#))
    #expect(request.body.range(of: Data("RIFF".utf8)) != nil)
    #expect(request.body.range(of: Data("WAVE".utf8)) != nil)
    let wavStart = try #require(request.body.range(of: Data("RIFF".utf8))?.lowerBound)
    #expect(request.body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: wavStart + 24, as: UInt32.self) }.littleEndian == 16_000)
    #expect(request.body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: wavStart + 22, as: UInt16.self) }.littleEndian == 1)
}

@Test
func openAICompatibleASRClientNormalizesStereoLowVolumeUploadTo16kMonoWAV() async throws {
    let source = ModelSource(
        id: "asr-openai",
        type: .asr,
        name: "OpenAI ASR",
        baseURL: "https://asr.example.test/v1/",
        selectedModel: "gpt-4o-transcribe"
    )
    let uploader = RecordingHTTPUploader(
        response: HTTPUploadResponse(
            data: #"{"text":"ok"}"#.data(using: .utf8)!,
            statusCode: 200
        )
    )
    let client = OpenAICompatibleASRClient(source: source, uploader: uploader)
    let chunk = AudioChunk(
        sequence: 8,
        startMs: 0,
        endMs: 500,
        samples: Array(repeating: Float(0.05), count: 48_000),
        format: AudioFormatDescription(sampleRate: 48_000, channels: 2)
    )

    _ = try await client.transcribe(chunk: chunk)
    let request = try await #require(uploader.recordedRequest())
    let wavStart = try #require(request.body.range(of: Data("RIFF".utf8))?.lowerBound)
    let sampleRate = request.body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: wavStart + 24, as: UInt32.self) }.littleEndian
    let channels = request.body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: wavStart + 22, as: UInt16.self) }.littleEndian
    let dataByteCount = request.body.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: wavStart + 40, as: UInt32.self) }.littleEndian

    #expect(sampleRate == 16_000)
    #expect(channels == 1)
    #expect(dataByteCount == 16_000)
}

@Test
func openAICompatibleASRClientAllowsEmptyTextForWarmup() async throws {
    let source = ModelSource(
        id: "asr-openai",
        type: .asr,
        name: "OpenAI ASR",
        baseURL: "https://asr.example.test/v1/",
        apiKey: "secret",
        selectedModel: "Qwen3-ASR-1.7B-8bit"
    )
    let uploader = RecordingHTTPUploader(
        response: HTTPUploadResponse(
            data: #"{"text":"","language":null,"segments":[{"text":"","start":0.0,"end":1.0}]}"#.data(using: .utf8)!,
            statusCode: 200
        )
    )
    let client = OpenAICompatibleASRClient(source: source, uploader: uploader)
    let chunk = AudioChunk(
        sequence: 0,
        startMs: 0,
        endMs: 300,
        samples: Array(repeating: 0, count: 4_800),
        format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
    )

    let segment = try await client.transcribe(chunk: chunk)

    #expect(segment.text == "")
    #expect(segment.startMs == 0)
    #expect(segment.endMs == 300)
}

@Test
func openAICompatibleASRClientFallsBackToSegmentText() async throws {
    let source = ModelSource(
        id: "asr-openai",
        type: .asr,
        name: "OpenAI ASR",
        baseURL: "https://asr.example.test/v1/",
        apiKey: "secret",
        selectedModel: "Qwen3-ASR-1.7B-8bit"
    )
    let uploader = RecordingHTTPUploader(
        response: HTTPUploadResponse(
            data: #"{"text":"","segments":[{"text":"第一句"},{"text":"第二句"}]}"#.data(using: .utf8)!,
            statusCode: 200
        )
    )
    let client = OpenAICompatibleASRClient(source: source, uploader: uploader)
    let chunk = AudioChunk(
        sequence: 1,
        startMs: 1_000,
        endMs: 2_000,
        samples: [0.1],
        format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
    )

    let segment = try await client.transcribe(chunk: chunk)

    #expect(segment.text == "第一句 第二句")
}

@Test
func asrClientErrorsAreReadableInChinese() {
    #expect(ASRClientError.missingModel.localizedDescription == "ASR 模型未选择，请先选择模型。")
    #expect(ASRClientError.invalidBaseURL.localizedDescription == "ASR 服务地址无效，请检查 baseURL。")
    #expect(ASRClientError.missingText.localizedDescription == "ASR 返回格式缺少 text 字段。")
    #expect(ASRClientError.invalidResponseStatus(401, "bad key").localizedDescription == "ASR 服务返回错误 401：bad key")
}

@Test
func compatibleVoiceprintClientUploadsWAVAndParsesEmbedding() async throws {
    let source = ModelSource(
        id: "voiceprint-compatible",
        type: .voiceprint,
        name: "声纹服务",
        baseURL: "https://voice.example.test/v1/",
        apiKey: "voice-secret",
        selectedModel: "speaker-embedding-v1"
    )
    let uploader = RecordingHTTPUploader(
        response: HTTPUploadResponse(
            data: #"{"embedding":[0.1,0.2,0.3],"confidence":0.86}"#.data(using: .utf8)!,
            statusCode: 200
        )
    )
    let client = CompatibleVoiceprintClient(source: source, uploader: uploader)
    let chunk = AudioChunk(
        sequence: 2,
        startMs: 4_000,
        endMs: 5_200,
        samples: [0.0, 0.3, -0.2],
        format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
    )

    let result = try await client.identify(chunk: chunk)
    let request = try await #require(uploader.recordedRequest())
    let bodyText = String(decoding: request.body, as: UTF8.self)

    #expect(result.embedding == [0.1, 0.2, 0.3])
    #expect(result.confidence == 0.86)
    #expect(request.url.absoluteString == "https://voice.example.test/v1/voiceprint/identify")
    #expect(request.headers["Authorization"] == "Bearer voice-secret")
    #expect(request.headers["Content-Type"]?.contains("multipart/form-data; boundary=") == true)
    #expect(bodyText.contains(#"name="model""#))
    #expect(bodyText.contains("speaker-embedding-v1"))
    #expect(bodyText.contains(#"filename="chunk-2.wav""#))
    #expect(request.body.range(of: Data("RIFF".utf8)) != nil)
}

@Test
func openAICompatiblePostprocessClientCallsChatCompletionsAndParsesText() async throws {
    let source = ModelSource(
        id: "postprocess-openai",
        type: .postprocess,
        name: "后处理服务",
        baseURL: "https://llm.example.test/v1/",
        apiKey: "llm-secret",
        selectedModel: "meeting-polish-v1"
    )
    let uploader = RecordingHTTPUploader(
        response: HTTPUploadResponse(
            data: #"{"choices":[{"message":{"content":"我们开始吧。"}}]}"#.data(using: .utf8)!,
            statusCode: 200
        )
    )
    let client = OpenAICompatiblePostprocessClient(source: source, uploader: uploader)

    let polished = try await client.polish(text: "我们开始吧")
    let request = try await #require(uploader.recordedRequest())
    let bodyText = String(decoding: request.body, as: UTF8.self)

    #expect(polished == "我们开始吧。")
    #expect(request.url.absoluteString == "https://llm.example.test/v1/chat/completions")
    #expect(request.headers["Authorization"] == "Bearer llm-secret")
    #expect(request.headers["Content-Type"] == "application/json")
    #expect(bodyText.contains("meeting-polish-v1"))
    #expect(bodyText.contains("删除明显口水词和语气填充词"))
    #expect(bodyText.contains("不要总结"))
    #expect(bodyText.contains("不要总结"))
    #expect(bodyText.contains("我们开始吧"))
}

@Test
func openAICompatiblePostprocessClientCallsResponsesAndParsesOutputText() async throws {
    let source = ModelSource(
        id: "postprocess-responses",
        type: .meetingMinutes,
        name: "GPT Responses 服务",
        baseURL: "https://api.openai.com/v1/",
        apiKey: "sk-test",
        apiProtocol: .responses,
        selectedModel: "gpt-4.1-mini"
    )
    let uploader = RecordingHTTPUploader(
        response: HTTPUploadResponse(
            data: ##"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"summary\":\"已完成\"}"}]}]}"##.data(using: .utf8)!,
            statusCode: 200
        )
    )
    let client = OpenAICompatiblePostprocessClient(
        source: source,
        uploader: uploader,
        forceJSONObject: true,
        disableThinking: true
    )

    let result = try await client.generateMeetingMinutes(
        systemPrompt: "只输出 JSON",
        userText: "会议内容"
    )
    let request = try await #require(uploader.recordedRequest())
    let bodyText = String(decoding: request.body, as: UTF8.self)

    #expect(result == #"{"summary":"已完成"}"#)
    #expect(request.url.absoluteString == "https://api.openai.com/v1/responses")
    #expect(request.headers["Authorization"] == "Bearer sk-test")
    #expect(bodyText.contains(#""model":"gpt-4.1-mini""#))
    #expect(bodyText.contains(#""instructions":"只输出 JSON""#))
    #expect(bodyText.contains(#""input":"会议内容""#))
    #expect(bodyText.contains(#""max_output_tokens":4096"#))
    #expect(bodyText.contains(#""store":false"#))
    #expect(!bodyText.contains(#""text":{"format":{"type":"json_object"}}"#))
    #expect(!bodyText.contains("chat_template_kwargs"))
}

@Test
func openAICompatiblePostprocessClientGeneratesMeetingMinutesWithConfiguredSource() async throws {
    let source = ModelSource(
        id: "postprocess-minutes",
        type: .postprocess,
        name: "会议纪要服务",
        baseURL: "https://llm.example.test/v1/",
        apiKey: "minutes-secret",
        selectedModel: "meeting-minutes-v1"
    )
    let uploader = RecordingHTTPUploader(
        response: HTTPUploadResponse(
            data: ##"{"choices":[{"message":{"content":"# 会议纪要\n\n## 待办事项\n| 事项 | 负责人 | 截止时间 | 状态 |"}}]}"##.data(using: .utf8)!,
            statusCode: 200
        )
    )
    let client = OpenAICompatiblePostprocessClient(source: source, uploader: uploader)

    let minutes = try await client.generateMeetingMinutes(
        systemPrompt: "会议纪要专用提示词",
        userText: "会议标题：项目评审\n原始转写：请确认交付时间。"
    )
    let request = try await #require(uploader.recordedRequest())
    let bodyText = String(decoding: request.body, as: UTF8.self)

    #expect(minutes.contains("# 会议纪要"))
    #expect(request.url.absoluteString == "https://llm.example.test/v1/chat/completions")
    #expect(request.headers["Authorization"] == "Bearer minutes-secret")
    #expect(bodyText.contains("meeting-minutes-v1"))
    #expect(bodyText.contains("会议纪要专用提示词"))
    #expect(bodyText.contains("项目评审"))
    #expect(bodyText.contains(#""max_tokens":4096"#))
}

@Test
func openAICompatiblePostprocessClientCanForceJSONObjectWithoutThinking() async throws {
    let source = ModelSource(
        id: "postprocess-json",
        type: .meetingMinutes,
        name: "会议纪要服务",
        baseURL: "https://llm.example.test/v1",
        selectedModel: "meeting-minutes-v1"
    )
    let uploader = RecordingHTTPUploader(
        response: HTTPUploadResponse(
            data: #"{"choices":[{"message":{"content":"{}"}}]}"#.data(using: .utf8)!,
            statusCode: 200
        )
    )
    let client = OpenAICompatiblePostprocessClient(
        source: source,
        uploader: uploader,
        forceJSONObject: true,
        disableThinking: true
    )

    _ = try await client.generateMeetingMinutes(systemPrompt: "只输出 JSON", userText: "会议内容")
    let request = try await #require(uploader.recordedRequest())
    let bodyText = String(decoding: request.body, as: UTF8.self)

    #expect(bodyText.contains(#""response_format":{"type":"json_object"}"#))
    #expect(bodyText.contains(#""chat_template_kwargs":{"enable_thinking":false}"#))
}

@Test
func openAICompatiblePostprocessClientUsesCustomPrompt() async throws {
    let source = ModelSource(
        id: "postprocess-openai-custom",
        type: .postprocess,
        name: "后处理服务",
        baseURL: "https://llm.example.test/v1/",
        apiKey: "llm-secret",
        selectedModel: "meeting-polish-v1"
    )
    let uploader = RecordingHTTPUploader(
        response: HTTPUploadResponse(
            data: #"{"choices":[{"message":{"content":"我们开始讨论方案。"}}]}"#.data(using: .utf8)!,
            statusCode: 200
        )
    )
    let prompt = "删除嗯、啊、呃等口水词，但保留原意。"
    let client = OpenAICompatiblePostprocessClient(source: source, uploader: uploader, prompt: prompt)

    _ = try await client.polish(text: "嗯我们啊开始讨论方案")
    let request = try await #require(uploader.recordedRequest())
    let bodyText = String(decoding: request.body, as: UTF8.self)

    #expect(bodyText.contains(prompt))
    #expect(!bodyText.contains("只做断句、标点和格式整理"))
}

@Test
func openAICompatiblePostprocessClientSendsMultimodalChatContent() async throws {
    let source = ModelSource(
        id: "vision-chat",
        type: .agent,
        name: "视觉会议模型",
        baseURL: "https://llm.example.test/v1",
        selectedModel: "vision-model",
        supportsVision: true
    )
    let uploader = RecordingHTTPUploader(
        response: HTTPUploadResponse(
            data: #"{"choices":[{"message":{"content":"{}"}}]}"#.data(using: .utf8)!,
            statusCode: 200
        )
    )
    let client = OpenAICompatiblePostprocessClient(source: source, uploader: uploader)

    _ = try await client.generateMeetingMinutes(
        systemPrompt: "只输出 JSON",
        userText: "请理解图片",
        images: [PostprocessImageInput(mimeType: "image/png", data: Data([1, 2, 3]))]
    )

    let request = try await #require(uploader.recordedRequest())
    let bodyText = String(decoding: request.body, as: UTF8.self)
    #expect(bodyText.contains("image_url"))
    #expect(bodyText.contains("base64,AQID"))
    #expect(bodyText.contains("detail"))
}

@Test
func openAICompatiblePostprocessClientSendsMultimodalResponsesContent() async throws {
    let source = ModelSource(
        id: "vision-responses",
        type: .agent,
        name: "视觉 Responses 模型",
        baseURL: "https://llm.example.test/v1",
        apiProtocol: .responses,
        selectedModel: "vision-model",
        supportsVision: true
    )
    let uploader = RecordingHTTPUploader(
        response: HTTPUploadResponse(
            data: #"{"output_text":"{}"}"#.data(using: .utf8)!,
            statusCode: 200
        )
    )
    let client = OpenAICompatiblePostprocessClient(source: source, uploader: uploader)

    _ = try await client.generateMeetingMinutes(
        systemPrompt: "只输出 JSON",
        userText: "请理解图片",
        images: [PostprocessImageInput(mimeType: "image/jpeg", data: Data([4, 5]))]
    )

    let request = try await #require(uploader.recordedRequest())
    let bodyText = String(decoding: request.body, as: UTF8.self)
    #expect(bodyText.contains("input_image"))
    #expect(bodyText.contains("base64,BAU="))
    #expect(bodyText.contains("\"role\":\"user\""))
    #expect(bodyText.contains("\"detail\":\"auto\""))
}

@Test
func openAICompatiblePostprocessClientRejectsImagesForTextOnlyModel() async throws {
    let source = ModelSource(
        id: "text-only",
        type: .agent,
        name: "文本会议模型",
        baseURL: "https://llm.example.test/v1",
        selectedModel: "text-model"
    )
    let uploader = RecordingHTTPUploader(
        response: HTTPUploadResponse(
            data: #"{"choices":[{"message":{"content":"{}"}}]}"#.data(using: .utf8)!,
            statusCode: 200
        )
    )
    let client = OpenAICompatiblePostprocessClient(source: source, uploader: uploader)

    await #expect(throws: PostprocessClientError.visionModelRequired) {
        _ = try await client.generateMeetingMinutes(
            systemPrompt: "只输出 JSON",
            userText: "请理解图片",
            images: [PostprocessImageInput(mimeType: "image/png", data: Data([1]))]
        )
    }
}

private struct MockHTTPDataLoader: HTTPDataLoading {
    var data: Data = #"{"data":[{"id":"mock-model"}]}"#.data(using: .utf8)!
    var statusCode = 200

    func data(from url: URL, headers: [String: String]) async throws -> Data {
        self.data
    }

    func response(from url: URL, headers: [String: String]) async throws -> HTTPDataLoadResponse {
        HTTPDataLoadResponse(data: data, statusCode: statusCode)
    }
}

private actor RecordingHTTPUploader: HTTPDataUploading {
    private var request: HTTPUploadRequest?
    private let response: HTTPUploadResponse

    init(response: HTTPUploadResponse) {
        self.response = response
    }

    func upload(request: HTTPUploadRequest) async throws -> HTTPUploadResponse {
        self.request = request
        return response
    }

    func recordedRequest() -> HTTPUploadRequest? {
        request
    }
}
