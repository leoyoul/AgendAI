import Foundation
import Testing
@testable import AItingjiCore

/// LiveSpeakerRecognizer 的三级匹配契约：
/// 1) 声纹库连续命中 → 返回姓名（Person.displayName）
/// 2) 未命中但会话内有相似 embedding / 同一 speaker track → 复用未知发言人标签
/// 3) 明显不同的新 speaker track 连续确认后 → 新增未知发言人 N
@Suite("LiveSpeakerRecognizer 三级匹配")
struct LiveSpeakerRecognizerTests {
    @Test("声纹库命中需要多窗口确认后返回姓名")
    func matchesKnownPersonAfterMultipleVotes() async {
        let zhangsanEmbedding = normalize([1.0, 0.05, 0.02])
        let people = [
            VoiceprintPerson(id: "person_zs", displayName: "张三", threshold: 0.75)
        ]
        let samples = [
            VoiceprintSample(id: "s1", personID: "person_zs", embedding: zhangsanEmbedding)
        ]
        let client = FakeDiarizationClient(embeddings: [zhangsanEmbedding, zhangsanEmbedding], turns: [
            [DiarizationTurn(startMs: 0, endMs: 2_000, speakerKey: "spk_zs", confidence: 0.9)],
            [DiarizationTurn(startMs: 2_000, endMs: 4_000, speakerKey: "spk_zs", confidence: 0.9)]
        ])
        let recognizer = LiveSpeakerRecognizer(
            diarizationClient: client,
            people: people,
            samples: samples,
            unknownThreshold: 0.75,
            minimumEmbeddingDurationMs: 100,
            workingDirectoryURL: makeTempDir()
        )

        let first = await recognizer.recognizeWindow(audioFilePath: "/tmp/fake.wav", chunkStartMs: 0, chunkEndMs: 2_000)
        let second = await recognizer.recognizeWindow(audioFilePath: "/tmp/fake.wav", chunkStartMs: 2_000, chunkEndMs: 4_000)
        #expect(first.resolution.personID == nil)
        #expect(first.resolution.label == "未知发言人 1")
        #expect(second.resolution.personID == "person_zs")
        #expect(second.resolution.personName == "张三")
        #expect(second.resolution.label == "张三")
        await recognizer.teardown()
    }

    @Test("同一未知说话人应复用同一标签")
    func reusesSessionUnknownLabelForSimilarEmbedding() async {
        let unknownA1 = normalize([0.1, 0.9, 0.05])
        let unknownA2 = normalize([0.11, 0.905, 0.06])  // 与 A1 近似 → 应复用
        let client = FakeDiarizationClient(embeddings: [unknownA1, unknownA2])
        let recognizer = LiveSpeakerRecognizer(
            diarizationClient: client,
            people: [],
            samples: [],
            unknownThreshold: 0.75,
            minimumEmbeddingDurationMs: 100,
            workingDirectoryURL: makeTempDir()
        )

        let first = await recognizer.recognize(chunk: makeChunk(sequence: 1, durationMs: 2000))
        let second = await recognizer.recognize(chunk: makeChunk(sequence: 2, durationMs: 2000))
        #expect(first.resolution.personID == nil)
        #expect(second.resolution.personID == nil)
        #expect(first.resolution.label == second.resolution.label)
        #expect(first.resolution.label.contains("未知发言人"))
        await recognizer.teardown()
    }

    @Test("极端差异的未知说话人需要连续确认后分别编号")
    func allocatesNewUnknownLabelForDifferentSpeakerAfterConfirmation() async {
        let unknownA = normalize([1.0, 0.0, 0.0])
        let unknownB1 = normalize([-1.0, 0.0, 0.0])
        let unknownB2 = normalize([-0.98, 0.05, 0.0])
        let unknownA2 = normalize([0.99, 0.03, 0.0])
        let client = FakeDiarizationClient(embeddings: [unknownA, unknownB1, unknownB2, unknownA2], turns: [
            [DiarizationTurn(startMs: 0, endMs: 2_000, speakerKey: "spk_0", confidence: 0.9)],
            [DiarizationTurn(startMs: 3_000, endMs: 5_000, speakerKey: "spk_1", confidence: 0.9)],
            [DiarizationTurn(startMs: 5_000, endMs: 7_000, speakerKey: "spk_1", confidence: 0.9)],
            [DiarizationTurn(startMs: 8_000, endMs: 10_000, speakerKey: "spk_0", confidence: 0.9)]
        ])
        let recognizer = LiveSpeakerRecognizer(
            diarizationClient: client,
            people: [],
            samples: [],
            unknownThreshold: 0.75,
            minimumEmbeddingDurationMs: 100,
            workingDirectoryURL: makeTempDir()
        )

        let a1 = await recognizer.recognizeWindow(audioFilePath: "/tmp/fake.wav", chunkStartMs: 0, chunkEndMs: 2_000)
        let b1 = await recognizer.recognizeWindow(audioFilePath: "/tmp/fake.wav", chunkStartMs: 3_000, chunkEndMs: 5_000)
        let b2 = await recognizer.recognizeWindow(audioFilePath: "/tmp/fake.wav", chunkStartMs: 5_000, chunkEndMs: 7_000)
        let a2 = await recognizer.recognizeWindow(audioFilePath: "/tmp/fake.wav", chunkStartMs: 8_000, chunkEndMs: 10_000)

        #expect(a1.resolution.label == "未知发言人 1")
        #expect(b1.resolution.label == "未知发言人 1")
        #expect(b2.resolution.label == "未知发言人 2")
        #expect(a2.resolution.label == "未知发言人 1")
        await recognizer.teardown()
    }

    @Test("实时连续短句优先复用最近未知发言人")
    func reusesRecentUnknownForNoisyConsecutiveUtterances() async {
        let first = normalize([1.0, 0.0, 0.0])
        let noisySameSpeaker = normalize([0.45, 0.89, 0.0])
        let client = FakeDiarizationClient(embeddings: [first, noisySameSpeaker])
        let recognizer = LiveSpeakerRecognizer(
            diarizationClient: client,
            people: [],
            samples: [],
            unknownThreshold: 0.68,
            minimumEmbeddingDurationMs: 100,
            workingDirectoryURL: makeTempDir()
        )

        let firstResult = await recognizer.recognize(chunk: makeChunk(sequence: 1, startMs: 0, durationMs: 2000))
        let secondResult = await recognizer.recognize(chunk: makeChunk(sequence: 2, startMs: 3000, durationMs: 2000))

        #expect(firstResult.resolution.label == "未知发言人 1")
        #expect(secondResult.resolution.label == "未知发言人 1")
        await recognizer.teardown()
    }

    @Test("短时极端差异先复用最近未知人，避免立刻新建")
    func defersNewUnknownForSingleNoisyOppositeUtterance() async {
        let first = normalize([1.0, 0.0, 0.0])
        let oppositeButSingle = normalize([-1.0, 0.0, 0.0])
        let client = FakeDiarizationClient(embeddings: [first, oppositeButSingle], turns: [
            [DiarizationTurn(startMs: 0, endMs: 2_000, speakerKey: "spk_0", confidence: 0.9)],
            [DiarizationTurn(startMs: 3_000, endMs: 5_000, speakerKey: "spk_1", confidence: 0.9)]
        ])
        let recognizer = LiveSpeakerRecognizer(
            diarizationClient: client,
            people: [],
            samples: [],
            unknownThreshold: 0.68,
            minimumEmbeddingDurationMs: 100,
            workingDirectoryURL: makeTempDir()
        )

        let firstResult = await recognizer.recognizeWindow(audioFilePath: "/tmp/fake.wav", chunkStartMs: 0, chunkEndMs: 2_000)
        let secondResult = await recognizer.recognizeWindow(audioFilePath: "/tmp/fake.wav", chunkStartMs: 3_000, chunkEndMs: 5_000)

        #expect(firstResult.resolution.label == "未知发言人 1")
        #expect(secondResult.resolution.label == "未知发言人 1")
        await recognizer.teardown()
    }

    @Test("连续确认的新 sidecar speaker 才新建未知发言人")
    func confirmsNewUnknownAfterRepeatedDifferentDiarizationKey() async {
        let first = normalize([1.0, 0.0, 0.0])
        let opposite1 = normalize([-1.0, 0.0, 0.0])
        let opposite2 = normalize([-0.98, 0.05, 0.0])
        let client = FakeDiarizationClient(embeddings: [first, opposite1, opposite2], turns: [
            [DiarizationTurn(startMs: 0, endMs: 2_000, speakerKey: "spk_0", confidence: 0.9)],
            [DiarizationTurn(startMs: 3_000, endMs: 5_000, speakerKey: "spk_1", confidence: 0.9)],
            [DiarizationTurn(startMs: 5_000, endMs: 7_000, speakerKey: "spk_1", confidence: 0.9)]
        ])
        let recognizer = LiveSpeakerRecognizer(
            diarizationClient: client,
            people: [],
            samples: [],
            unknownThreshold: 0.68,
            minimumEmbeddingDurationMs: 100,
            workingDirectoryURL: makeTempDir()
        )

        let firstResult = await recognizer.recognizeWindow(audioFilePath: "/tmp/fake.wav", chunkStartMs: 0, chunkEndMs: 2_000)
        let secondResult = await recognizer.recognizeWindow(audioFilePath: "/tmp/fake.wav", chunkStartMs: 3_000, chunkEndMs: 5_000)
        let thirdResult = await recognizer.recognizeWindow(audioFilePath: "/tmp/fake.wav", chunkStartMs: 5_000, chunkEndMs: 7_000)

        #expect(firstResult.resolution.label == "未知发言人 1")
        #expect(secondResult.resolution.label == "未知发言人 1")
        #expect(thirdResult.resolution.label == "未知发言人 2")
        await recognizer.teardown()
    }

    @Test("chunk 过短时回退临时发言人，不阻塞 pipeline")
    func fallsBackToTemporaryUnknownWhenChunkTooShort() async {
        let client = FakeDiarizationClient(embeddings: [normalize([1.0, 0.0, 0.0])])
        let recognizer = LiveSpeakerRecognizer(
            diarizationClient: client,
            people: [],
            samples: [],
            unknownThreshold: 0.75,
            minimumEmbeddingDurationMs: 1500,
            workingDirectoryURL: makeTempDir()
        )
        let result = await recognizer.recognize(chunk: makeChunk(sequence: 1, durationMs: 500))
        #expect(result.embedding.isEmpty)
        #expect(result.resolution.personID == nil)
        // 未调用 sidecar
        #expect(await client.callCount == 0)
        await recognizer.teardown()
    }
}

// MARK: - Test helpers

private actor FakeDiarizationClient: DiarizationClient {
    private var embeddings: [[Double]]
    private var turns: [[DiarizationTurn]]
    private(set) var callCount = 0

    init(embeddings: [[Double]], turns: [[DiarizationTurn]] = []) {
        self.embeddings = embeddings
        self.turns = turns
    }

    func health() async throws -> DiarizationHealth {
        DiarizationHealth(status: "ready", models: ["fake"])
    }

    func preload(huggingFaceToken: String?) async throws -> DiarizationHealth {
        DiarizationHealth(status: "ready", models: ["fake"])
    }

    func diarizeFile(path: String, speakerConstraint: DiarizationSpeakerConstraint) async throws -> [DiarizationTurn] {
        []
    }

    func diarizeWindow(path: String, startMs: Int, endMs: Int, speakerConstraint: DiarizationSpeakerConstraint) async throws -> [DiarizationTurn] {
        guard !turns.isEmpty else { return [] }
        return turns.removeFirst()
    }

    func embedSpeaker(path: String, startMs: Int, endMs: Int) async throws -> VoiceprintResult {
        callCount += 1
        guard !embeddings.isEmpty else {
            throw DiarizationClientError.transport("no more fake embeddings")
        }
        let next = embeddings.removeFirst()
        return VoiceprintResult(embedding: next, confidence: 0.9)
    }
}

private func makeChunk(sequence: Int, startMs: Int = 0, durationMs: Int) -> AudioChunk {
    let sampleCount = max(1, Int(16_000.0 * Double(durationMs) / 1000.0))
    return AudioChunk(
        sequence: sequence,
        startMs: startMs,
        endMs: startMs + durationMs,
        samples: Array(repeating: 0.01 as Float, count: sampleCount),
        format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
    )
}

private func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("live-speaker-recognizer-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func normalize(_ v: [Double]) -> [Double] {
    let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
    guard norm > 0 else { return v }
    return v.map { $0 / norm }
}
