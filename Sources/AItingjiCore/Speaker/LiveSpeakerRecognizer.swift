import Foundation

/// 实时链路里 chunk 级声纹识别的结果。用于回填 TranscriptSegment 的 speakerLabel。
public struct LiveSpeakerRecognitionResult: Equatable, Sendable {
    public var resolution: SpeakerResolution
    public var embedding: [Double]
    /// 该 embedding 的原始置信度（来自 sidecar backend）。
    public var embeddingConfidence: Double

    public init(resolution: SpeakerResolution, embedding: [Double], embeddingConfidence: Double) {
        self.resolution = resolution
        self.embedding = embedding
        self.embeddingConfidence = embeddingConfidence
    }
}

/// 会话级实时声纹管道：
/// 1) 用 sidecar 提取实时窗口里的主说话人 turn
/// 2) 对主 turn 提 embedding
/// 3) 先匹配跨会话声纹库；未命中时用会话级保守 stitching 生成稳定未知人
///
/// 重要原则：实时短句 embedding 本身不可靠，不能每次低于阈值就新建未知人。
/// 新未知人只在“sidecar 换人 + embedding 明显相反/持续出现”时确认。
public actor LiveSpeakerRecognizer {
    private struct PendingUnknownCandidate: Sendable {
        var diarizationKey: String?
        var resolution: SpeakerResolution
        var embedding: [Double]
        var firstSeenEndMs: Int
        var lastSeenEndMs: Int
        var observations: Int
    }

    private struct KnownVoteState: Sendable {
        var personID: String
        var personName: String
        var votes: Int
        var bestScore: Double
        var lastSeenEndMs: Int
    }

    private let diarizationClient: any DiarizationClient
    private let minimumEmbeddingDurationMs: Int
    private var resolver: SpeakerResolver
    private var peopleByID: [String: VoiceprintPerson]
    private var samples: [VoiceprintSample]
    /// 实时短句场景下 ECAPA embedding 波动很大；缓存最近未知人，避免每句话都新增。
    private var recentUnknownResolution: SpeakerResolution?
    private var recentUnknownEmbedding: [Double]?
    private var recentUnknownEndMs: Int?
    private let recentUnknownReuseWindowMs = 20_000
    private let recentUnknownContinuityThreshold = 0.25
    /// sidecar 在滑窗内给出的 speakerKey 比单次 embedding 更适合做“同一会话内身份锚点”。
    private var unknownResolutionByDiarizationKey: [String: SpeakerResolution] = [:]
    private var unknownEmbeddingByDiarizationKey: [String: [Double]] = [:]
    private var pendingUnknownCandidate: PendingUnknownCandidate?
    private var knownVoteByDiarizationKey: [String: KnownVoteState] = [:]
    /// 只有特别不像最近未知人时才允许确认新未知人；否则宁可先复用，避免一人多号。
    private let obviousDifferentSpeakerThreshold = 0.05
    private let unknownKeyReuseThreshold = 0.35
    private let pendingCandidateMaxAgeMs = 12_000
    private let immediateNewUnknownDurationMs = 8_000
    private let knownVoteWindowMs = 18_000
    private let minimumKnownVotes = 2
    private let immediateKnownDurationMs = 8_000
    /// 临时 wav 文件目录（`FileManager.temporaryDirectory` 下的一个子目录）。
    private let workingDirectoryURL: URL

    public init(
        diarizationClient: any DiarizationClient,
        people: [VoiceprintPerson],
        samples: [VoiceprintSample],
        unknownThreshold: Double = 0.68,
        minimumEmbeddingDurationMs: Int = 800,
        workingDirectoryURL: URL? = nil
    ) {
        self.diarizationClient = diarizationClient
        self.minimumEmbeddingDurationMs = minimumEmbeddingDurationMs
        self.peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        self.samples = samples
        self.resolver = SpeakerResolver(
            people: people,
            samples: samples,
            unknownThreshold: unknownThreshold
        )
        let baseDir = workingDirectoryURL
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "live-voiceprint-\(UUID().uuidString)",
                isDirectory: true
            )
        self.workingDirectoryURL = baseDir
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }

    /// 用最新的声纹库信息重建 resolver（例如刚追加了一个 person / sample 时调用）。
    /// 注意：会重置“会话内未知发言人”编号；只在录音间隙调用。
    public func refreshVoiceprintLibrary(people: [VoiceprintPerson], samples: [VoiceprintSample]) {
        peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        self.samples = samples
        resolver = SpeakerResolver(people: people, samples: samples)
        recentUnknownResolution = nil
        recentUnknownEmbedding = nil
        recentUnknownEndMs = nil
        unknownResolutionByDiarizationKey = [:]
        unknownEmbeddingByDiarizationKey = [:]
        pendingUnknownCandidate = nil
        knownVoteByDiarizationKey = [:]
    }

    /// 主入口：对当前 chunk 完成一次“声纹提取 + 三级匹配”。
    /// 失败或音频过短时回退到 `allocateTemporaryUnknown`，避免阻塞 UI。
    public func recognize(chunk: AudioChunk) async -> LiveSpeakerRecognitionResult {
        let durationMs = chunk.endMs - chunk.startMs
        guard durationMs >= minimumEmbeddingDurationMs else {
            return fallbackUnknown(chunkEndMs: chunk.endMs)
        }
        do {
            let wavURL = try writeTemporaryWav(chunk: chunk)
            defer { try? FileManager.default.removeItem(at: wavURL) }
            let effectiveEndMs = max(1, wavDurationEstimateMs(chunk: chunk))
            return try await resolveEmbedding(
                path: wavURL.path,
                startMs: 0,
                endMs: effectiveEndMs,
                chunkEndMs: chunk.endMs,
                diarizationKey: nil
            )
        } catch {
            return fallbackUnknown(chunkEndMs: chunk.endMs)
        }
    }

    /// 更稳定的主入口：先对当前音频文件做实时滑窗分离，选出与 ASR chunk 重叠最多的 turn，
    /// 再只对该 turn 提 embedding。相比直接对整块 chunk 提 embedding，能显著降低多人重叠/换人边界导致的误判。
    public func recognizeWindow(
        audioFilePath: String,
        chunkStartMs: Int,
        chunkEndMs: Int,
        lookbackMs: Int = 18_000,
        tailPaddingMs: Int = 1_200,
        speakerConstraint: DiarizationSpeakerConstraint = .automatic
    ) async -> LiveSpeakerRecognitionResult {
        guard chunkEndMs - chunkStartMs >= minimumEmbeddingDurationMs else {
            return fallbackUnknown(chunkEndMs: chunkEndMs)
        }
        let windowStartMs = max(0, chunkStartMs - lookbackMs)
        let windowEndMs = max(chunkEndMs, chunkEndMs + tailPaddingMs)
        do {
            let turns = try await diarizationClient.diarizeWindow(
                path: audioFilePath,
                startMs: windowStartMs,
                endMs: windowEndMs,
                speakerConstraint: speakerConstraint
            )
            guard let turn = bestTurn(overlappingStartMs: chunkStartMs, endMs: chunkEndMs, turns: turns) else {
                return fallbackUnknown(chunkEndMs: chunkEndMs)
            }
            let startMs = max(0, turn.startMs)
            let endMs = max(startMs + 1, turn.endMs)
            guard endMs - startMs >= minimumEmbeddingDurationMs else {
                return fallbackUnknown(chunkEndMs: chunkEndMs)
            }
            return try await resolveEmbedding(
                path: audioFilePath,
                startMs: startMs,
                endMs: endMs,
                chunkEndMs: chunkEndMs,
                diarizationKey: turn.speakerKey
            )
        } catch {
            return fallbackUnknown(chunkEndMs: chunkEndMs)
        }
    }

    /// 主动释放临时目录。调用后不应再复用当前实例。
    public func teardown() {
        try? FileManager.default.removeItem(at: workingDirectoryURL)
    }

    private func resolveEmbedding(
        path: String,
        startMs: Int,
        endMs: Int,
        chunkEndMs: Int,
        diarizationKey: String?
    ) async throws -> LiveSpeakerRecognitionResult {
        let voiceprint = try await diarizationClient.embedSpeaker(
            path: path,
            startMs: startMs,
            endMs: endMs
        )
        let durationMs = max(0, endMs - startMs)
        if let known = stableKnownResolution(
            embedding: voiceprint.embedding,
            confidence: voiceprint.confidence,
            chunkEndMs: chunkEndMs,
            diarizationKey: diarizationKey,
            durationMs: durationMs
        ) {
            return LiveSpeakerRecognitionResult(
                resolution: known,
                embedding: voiceprint.embedding,
                embeddingConfidence: voiceprint.confidence
            )
        }
        let rawResolution = resolver.resolve(
            embedding: voiceprint.embedding,
            confidence: 0
        )
        let resolution = stabilizeResolution(
            rawResolution,
            embedding: voiceprint.embedding,
            chunkEndMs: chunkEndMs,
            diarizationKey: diarizationKey,
            durationMs: durationMs
        )
        return LiveSpeakerRecognitionResult(
            resolution: resolution,
            embedding: voiceprint.embedding,
            embeddingConfidence: voiceprint.confidence
        )
    }

    private func fallbackUnknown(chunkEndMs: Int? = nil) -> LiveSpeakerRecognitionResult {
        let resolution: SpeakerResolution
        if let chunkEndMs,
           let recent = reusableRecentUnknown(at: chunkEndMs) {
            resolution = recent
        } else {
            resolution = resolver.allocateTemporaryUnknown(confidence: 0)
            if resolution.personID == nil, let chunkEndMs {
                rememberUnknown(resolution, embedding: nil, chunkEndMs: chunkEndMs, diarizationKey: nil)
            }
        }
        return LiveSpeakerRecognitionResult(
            resolution: resolution,
            embedding: [],
            embeddingConfidence: 0
        )
    }

    private func stableKnownResolution(
        embedding: [Double],
        confidence: Double,
        chunkEndMs: Int,
        diarizationKey: String?,
        durationMs: Int
    ) -> SpeakerResolution? {
        guard confidence >= VoiceprintMatchingPolicy.minimumRecognitionConfidence,
              let known = bestKnownMatch(for: embedding) else {
            return nil
        }
        let key = diarizationKey ?? "__single_stream__"
        let previous = knownVoteByDiarizationKey[key]
        let votes: Int
        if let previous,
           previous.personID == known.person.id,
           chunkEndMs - previous.lastSeenEndMs <= knownVoteWindowMs {
            votes = previous.votes + 1
        } else {
            votes = 1
        }
        knownVoteByDiarizationKey[key] = KnownVoteState(
            personID: known.person.id,
            personName: known.person.displayName,
            votes: votes,
            bestScore: max(previous?.bestScore ?? 0, known.score),
            lastSeenEndMs: chunkEndMs
        )

        guard votes >= minimumKnownVotes || durationMs >= immediateKnownDurationMs else {
            return nil
        }

        recentUnknownResolution = nil
        recentUnknownEmbedding = nil
        recentUnknownEndMs = nil
        pendingUnknownCandidate = nil
        return SpeakerResolution(
            label: known.person.displayName,
            autoLabel: known.person.displayName,
            personID: known.person.id,
            personName: known.person.displayName,
            confidence: min(1, max(confidence, known.score))
        )
    }

    private func bestKnownMatch(for embedding: [Double]) -> (person: VoiceprintPerson, score: Double)? {
        var bestByPersonID: [String: (person: VoiceprintPerson, score: Double)] = [:]
        for sample in samples {
            guard VoiceprintMatchingPolicy.isKnownSampleEligible(sample),
                  let person = peopleByID[sample.personID],
                  person.isActive else {
                continue
            }
            let score = cosineSimilarity(embedding, sample.embedding)
            guard score >= VoiceprintMatchingPolicy.safeThreshold(for: person) else {
                continue
            }
            if let existing = bestByPersonID[person.id], existing.score >= score {
                continue
            }
            bestByPersonID[person.id] = (person, score)
        }
        let candidates = bestByPersonID.values.sorted { $0.score > $1.score }
        guard let best = candidates.first else { return nil }
        if candidates.count > 1,
           best.score - candidates[1].score < VoiceprintMatchingPolicy.minimumLeadMargin {
            return nil
        }
        return best
    }

    private func stabilizeResolution(
        _ resolution: SpeakerResolution,
        embedding: [Double],
        chunkEndMs: Int,
        diarizationKey: String?,
        durationMs: Int
    ) -> SpeakerResolution {
        guard resolution.personID == nil else {
            // 已命中声纹库实名：实名优先，清掉待确认未知候选，避免真人切回未知时误复用。
            recentUnknownResolution = nil
            recentUnknownEmbedding = nil
            recentUnknownEndMs = nil
            pendingUnknownCandidate = nil
            return resolution
        }

        let normalizedEmbedding = normalized(embedding)
        if let diarizationKey,
           let mapped = unknownResolutionByDiarizationKey[diarizationKey] {
            rememberUnknown(mapped, embedding: normalizedEmbedding, chunkEndMs: chunkEndMs, diarizationKey: diarizationKey)
            return mapped
        }

        if let matched = bestMappedUnknown(for: normalizedEmbedding) {
            rememberUnknown(matched.resolution, embedding: normalizedEmbedding, chunkEndMs: chunkEndMs, diarizationKey: diarizationKey)
            return matched.resolution
        }

        guard let recentUnknownResolution,
              recentUnknownResolution.personID == nil else {
            rememberUnknown(resolution, embedding: normalizedEmbedding, chunkEndMs: chunkEndMs, diarizationKey: diarizationKey)
            return resolution
        }

        let similarityToRecent = recentUnknownEmbedding.map { cosineSimilarity(normalizedEmbedding, $0) } ?? 1
        let looksObviouslyDifferent = similarityToRecent < obviousDifferentSpeakerThreshold

        guard looksObviouslyDifferent else {
            rememberUnknown(recentUnknownResolution, embedding: normalizedEmbedding, chunkEndMs: chunkEndMs, diarizationKey: diarizationKey)
            return recentUnknownResolution
        }

        if shouldAcceptNewUnknownCandidate(
            resolution: resolution,
            embedding: normalizedEmbedding,
            chunkEndMs: chunkEndMs,
            diarizationKey: diarizationKey,
            durationMs: durationMs
        ) {
            pendingUnknownCandidate = nil
            rememberUnknown(resolution, embedding: normalizedEmbedding, chunkEndMs: chunkEndMs, diarizationKey: diarizationKey)
            return resolution
        }

        rememberUnknown(recentUnknownResolution, embedding: recentUnknownEmbedding, chunkEndMs: chunkEndMs, diarizationKey: nil)
        return recentUnknownResolution
    }

    private func shouldAcceptNewUnknownCandidate(
        resolution: SpeakerResolution,
        embedding: [Double],
        chunkEndMs: Int,
        diarizationKey: String?,
        durationMs: Int
    ) -> Bool {
        if durationMs >= immediateNewUnknownDurationMs,
           diarizationKey != nil {
            return true
        }

        if let pendingUnknownCandidate,
           pendingUnknownCandidate.diarizationKey == diarizationKey,
           chunkEndMs - pendingUnknownCandidate.firstSeenEndMs <= pendingCandidateMaxAgeMs {
            self.pendingUnknownCandidate = PendingUnknownCandidate(
                diarizationKey: diarizationKey,
                resolution: resolution,
                embedding: mergeRecentEmbedding(old: pendingUnknownCandidate.embedding, new: embedding),
                firstSeenEndMs: pendingUnknownCandidate.firstSeenEndMs,
                lastSeenEndMs: chunkEndMs,
                observations: pendingUnknownCandidate.observations + 1
            )
            return pendingUnknownCandidate.observations + 1 >= 2
        }

        pendingUnknownCandidate = PendingUnknownCandidate(
            diarizationKey: diarizationKey,
            resolution: resolution,
            embedding: embedding,
            firstSeenEndMs: chunkEndMs,
            lastSeenEndMs: chunkEndMs,
            observations: 1
        )
        return false
    }

    private func bestMappedUnknown(for embedding: [Double]) -> (resolution: SpeakerResolution, score: Double)? {
        unknownEmbeddingByDiarizationKey.compactMap { key, storedEmbedding -> (SpeakerResolution, Double)? in
            guard let resolution = unknownResolutionByDiarizationKey[key] else { return nil }
            return (resolution, cosineSimilarity(embedding, storedEmbedding))
        }
        .filter { $0.1 >= unknownKeyReuseThreshold }
        .max { left, right in left.1 < right.1 }
    }

    private func rememberUnknown(
        _ resolution: SpeakerResolution,
        embedding: [Double]?,
        chunkEndMs: Int,
        diarizationKey: String?
    ) {
        recentUnknownResolution = resolution
        if let embedding, !embedding.isEmpty {
            recentUnknownEmbedding = mergeRecentEmbedding(old: recentUnknownEmbedding, new: embedding)
        }
        recentUnknownEndMs = chunkEndMs
        if let diarizationKey {
            unknownResolutionByDiarizationKey[diarizationKey] = resolution
            if let embedding, !embedding.isEmpty {
                unknownEmbeddingByDiarizationKey[diarizationKey] = mergeRecentEmbedding(
                    old: unknownEmbeddingByDiarizationKey[diarizationKey],
                    new: embedding
                )
            }
        }
    }

    private func reusableRecentUnknown(at chunkEndMs: Int, embedding: [Double]? = nil) -> SpeakerResolution? {
        guard let recentUnknownResolution,
              recentUnknownResolution.personID == nil,
              let recentUnknownEndMs,
              chunkEndMs - recentUnknownEndMs <= recentUnknownReuseWindowMs else {
            return nil
        }
        if let embedding,
           let recentUnknownEmbedding,
           !embedding.isEmpty,
           cosineSimilarity(normalized(embedding), recentUnknownEmbedding) < recentUnknownContinuityThreshold {
            return nil
        }
        return recentUnknownResolution
    }

    private func mergeRecentEmbedding(old: [Double]?, new: [Double]) -> [Double] {
        let normalizedNew = normalized(new)
        guard let old, old.count == normalizedNew.count, !old.isEmpty else {
            return normalizedNew
        }
        let alpha = 0.80
        return normalized(zip(old, normalizedNew).map { alpha * $0.0 + (1 - alpha) * $0.1 })
    }

    private func normalized(_ embedding: [Double]) -> [Double] {
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return embedding }
        return embedding.map { $0 / norm }
    }

    private func bestTurn(overlappingStartMs startMs: Int, endMs: Int, turns: [DiarizationTurn]) -> DiarizationTurn? {
        turns
            .map { turn -> (turn: DiarizationTurn, overlap: Int, duration: Int, midpointHit: Bool) in
                let overlap = max(0, min(endMs, turn.endMs) - max(startMs, turn.startMs))
                let midpoint = startMs + max(0, endMs - startMs) / 2
                return (turn, overlap, max(0, turn.endMs - turn.startMs), turn.startMs <= midpoint && midpoint < turn.endMs)
            }
            .filter { $0.overlap > 0 }
            .sorted { left, right in
                if left.midpointHit != right.midpointHit {
                    return left.midpointHit
                }
                if left.overlap == right.overlap {
                    if left.turn.confidence == right.turn.confidence {
                        return left.duration > right.duration
                    }
                    return left.turn.confidence > right.turn.confidence
                }
                return left.overlap > right.overlap
            }
            .first?
            .turn
    }

    private func writeTemporaryWav(chunk: AudioChunk) throws -> URL {
        try FileManager.default.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)
        let url = workingDirectoryURL.appendingPathComponent("chunk-\(UUID().uuidString).wav")
        let wav = WAVEncoder.encode(chunk: chunk)
        try wav.write(to: url, options: .atomic)
        return url
    }

    /// WAVEncoder 会把音频重采样到 16 kHz 单声道再写文件，因此按 chunk 时长直接返回即可。
    /// 传给 sidecar 的 startMs/endMs 需要一个上限；给一个略保守的整块时长即可。
    private func wavDurationEstimateMs(chunk: AudioChunk) -> Int {
        max(0, chunk.endMs - chunk.startMs)
    }
}
