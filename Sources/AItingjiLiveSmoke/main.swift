import AItingjiCore
import Foundation

@main
struct AItingjiLiveSmoke {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else {
            print("usage: AItingjiLiveSmoke <microphone|screen-audio> [delay-seconds]")
            Foundation.exit(2)
        }

        do {
            let source = CommandLine.arguments[1]
            let delaySeconds = CommandLine.arguments.count >= 3
                ? Int(CommandLine.arguments[2]) ?? 0
                : 0
            let chunk = try await captureFirstChunk(source: source, delaySeconds: delaySeconds)
            let result = try await transcribe(chunk: chunk)
            print("source=\(source)")
            print("samples=\(chunk.samples.count)")
            print("text=\(result.text)")
            if result.text.isEmpty {
                print("empty_text=true")
            }
        } catch {
            print("live_smoke_failed=\(error)")
            Foundation.exit(1)
        }
    }

    private static func captureFirstChunk(source: String, delaySeconds: Int) async throws -> AudioChunk {
        let capture: AudioCaptureSession
        switch source {
        case "microphone":
            capture = MicrophoneCapture()
        case "screen-audio":
            capture = ScreenAudioCapture()
        default:
            throw AudioCaptureError.unsupported("未知采集来源：\(source)")
        }

        let box = SampleAccumulator(isArmed: delaySeconds <= 0)
        try await capture.start(
            callbacks: AudioCaptureCallbacks(
                onChunk: { chunk in
                    Task {
                        await box.add(chunk)
                    }
                },
                onError: { error in
                    print("capture_error=\(error)")
                }
            )
        )
        if delaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            await box.arm()
        }
        defer {
            Task {
                await capture.stop()
            }
        }

        for _ in 0..<80 {
            if let chunk = await box.value() {
                await capture.stop()
                return chunk
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await capture.stop()
        throw AudioCaptureError.startFailed("8 秒内没有采到可转写音频")
    }

    private static func transcribe(chunk: AudioChunk) async throws -> ASRSegment {
        let source = ModelSource(
            id: "local-qwen3-asr",
            type: .asr,
            name: "本地 Qwen3 ASR",
            baseURL: "http://127.0.0.1:18001/v1",
            apiKey: "1234",
            selectedModel: "Qwen3-ASR-1.7B-8bit"
        )
        return try await OpenAICompatibleASRClient(
            source: source,
            uploader: URLSessionDataUploader(session: HTTPSessionFactory.asr())
        ).transcribe(chunk: chunk)
    }
}

private actor SampleAccumulator {
    private var accumulator = AudioChunkAccumulator(targetDurationMs: 3000)
    private var chunk: AudioChunk?
    private var isArmed: Bool

    init(isArmed: Bool) {
        self.isArmed = isArmed
    }

    func arm() {
        isArmed = true
    }

    func add(_ chunk: AudioChunk) {
        guard isArmed, self.chunk == nil else {
            return
        }
        if let output = accumulator.append(chunk) {
            self.chunk = output
        }
    }

    func value() -> AudioChunk? {
        chunk
    }
}
