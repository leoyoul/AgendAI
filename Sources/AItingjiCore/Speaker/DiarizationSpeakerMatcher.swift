import Foundation

public enum DiarizationSpeakerMatcher {
    public static func preservingManualMappings(
        existing: [DiarizationSpeakerMapping],
        automatic: [DiarizationSpeakerMapping]
    ) -> [DiarizationSpeakerMapping] {
        let manualByKey = Dictionary(
            uniqueKeysWithValues: existing.filter(\.isManual).map { ($0.speakerKey, $0) }
        )
        return automatic.map { manualByKey[$0.speakerKey] ?? $0 }
    }

    public static func buildMappings(
        meetingID: String,
        turns: [DiarizationTurn],
        embeddingsBySpeakerKey: [String: VoiceprintResult],
        people: [VoiceprintPerson],
        samples: [VoiceprintSample]
    ) -> [DiarizationSpeakerMapping] {
        buildMappings(
            meetingID: meetingID,
            turns: turns,
            embeddingCandidatesBySpeakerKey: embeddingsBySpeakerKey.mapValues { [$0] },
            people: people,
            samples: samples
        )
    }

    public static func buildMappings(
        meetingID: String,
        turns: [DiarizationTurn],
        embeddingCandidatesBySpeakerKey: [String: [VoiceprintResult]],
        people: [VoiceprintPerson],
        samples: [VoiceprintSample]
    ) -> [DiarizationSpeakerMapping] {
        let speakerKeys = orderedSpeakerKeys(turns: turns)
        let peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        var mappings: [DiarizationSpeakerMapping] = []
        var nextUnknownIndex = 1

        for speakerKey in speakerKeys {
            let candidates = embeddingCandidatesBySpeakerKey[speakerKey, default: []]
                .filter { !$0.embedding.isEmpty }
            let match = bestKnownMatch(candidates: candidates, peopleByID: peopleByID, samples: samples)
            let speakerLabel: String
            let personID: String?
            let personName: String?
            let confidence: Double
            if let match {
                speakerLabel = match.person.displayName
                personID = match.person.id
                personName = match.person.displayName
                confidence = match.score
            } else {
                speakerLabel = "未知发言人 \(nextUnknownIndex)"
                personID = nil
                personName = nil
                confidence = candidates.map(\.confidence).max() ?? 0
                nextUnknownIndex += 1
            }

            mappings.append(
                DiarizationSpeakerMapping(
                    meetingID: meetingID,
                    speakerKey: speakerKey,
                    speakerLabel: speakerLabel,
                    personID: personID,
                    personName: personName,
                    confidence: confidence
                )
            )
        }

        return mappings
    }

    /// ECAPA 短片段（<1500ms）余弦相似度震荡大，
    /// 用更长的最小窗口能显著提高声纹稳定性。
    public static let defaultMinimumEmbeddingWindowMs = 1500
    public static let fallbackMinimumEmbeddingWindowMs = 800

    public static func bestEmbeddingWindow(
        for speakerKey: String,
        turns: [DiarizationTurn],
        minimumDurationMs: Int = defaultMinimumEmbeddingWindowMs
    ) -> DiarizationTurn? {
        if let best = pickLongestTurn(speakerKey: speakerKey, turns: turns, minimumDurationMs: minimumDurationMs) {
            return best
        }
        // 短会议里可能连 1.5s 都凑不出，退化到 800ms 起。
        if minimumDurationMs > fallbackMinimumEmbeddingWindowMs {
            return pickLongestTurn(
                speakerKey: speakerKey,
                turns: turns,
                minimumDurationMs: fallbackMinimumEmbeddingWindowMs
            )
        }
        return nil
    }

    public static func embeddingWindows(
        for speakerKey: String,
        turns: [DiarizationTurn],
        minimumDurationMs: Int = defaultMinimumEmbeddingWindowMs,
        limit: Int = 3
    ) -> [DiarizationTurn] {
        let primary = pickTurns(
            speakerKey: speakerKey,
            turns: turns,
            minimumDurationMs: minimumDurationMs,
            limit: limit
        )
        if !primary.isEmpty { return primary }
        if minimumDurationMs > fallbackMinimumEmbeddingWindowMs {
            return pickTurns(
                speakerKey: speakerKey,
                turns: turns,
                minimumDurationMs: fallbackMinimumEmbeddingWindowMs,
                limit: limit
            )
        }
        return []
    }

    private static func pickLongestTurn(
        speakerKey: String,
        turns: [DiarizationTurn],
        minimumDurationMs: Int
    ) -> DiarizationTurn? {
        turns
            .filter { $0.speakerKey == speakerKey && $0.endMs - $0.startMs >= minimumDurationMs }
            .max { left, right in
                let leftDuration = left.endMs - left.startMs
                let rightDuration = right.endMs - right.startMs
                if leftDuration == rightDuration {
                    return left.confidence < right.confidence
                }
                return leftDuration < rightDuration
            }
    }

    private static func pickTurns(
        speakerKey: String,
        turns: [DiarizationTurn],
        minimumDurationMs: Int,
        limit: Int
    ) -> [DiarizationTurn] {
        turns
            .filter { $0.speakerKey == speakerKey && $0.endMs - $0.startMs >= minimumDurationMs }
            .sorted { left, right in
                let leftDuration = left.endMs - left.startMs
                let rightDuration = right.endMs - right.startMs
                if left.confidence == right.confidence {
                    return leftDuration > rightDuration
                }
                return left.confidence > right.confidence
            }
            .prefix(max(1, limit))
            .map { $0 }
    }

    private static func bestKnownMatch(
        candidates: [VoiceprintResult],
        peopleByID: [String: VoiceprintPerson],
        samples: [VoiceprintSample]
    ) -> (person: VoiceprintPerson, score: Double)? {
        guard !candidates.isEmpty else {
            return nil
        }
        // 每人可用样本数
        var sampleCountByPersonID: [String: Int] = [:]
        for sample in samples where VoiceprintMatchingPolicy.isKnownSampleEligible(sample) {
            guard let person = peopleByID[sample.personID], person.isActive else { continue }
            sampleCountByPersonID[person.id, default: 0] += 1
        }

        var scoresByPersonID: [String: (person: VoiceprintPerson, scores: [Double])] = [:]
        for sample in samples where VoiceprintMatchingPolicy.isKnownSampleEligible(sample) {
            guard let person = peopleByID[sample.personID], person.isActive else {
                continue
            }
            let threshold = VoiceprintMatchingPolicy.safeThreshold(for: person)
            for candidate in candidates where candidate.confidence >= VoiceprintMatchingPolicy.minimumRecognitionConfidence {
                let score = cosineSimilarity(candidate.embedding, sample.embedding)
                guard score >= threshold else {
                    continue
                }
                var bucket = scoresByPersonID[person.id] ?? (person, [])
                bucket.scores.append(score)
                scoresByPersonID[person.id] = bucket
            }
        }
        let ranked = scoresByPersonID.values
            .map { item -> (person: VoiceprintPerson, score: Double, hitCount: Int) in
                let topScores = item.scores.sorted(by: >).prefix(3)
                let average = topScores.reduce(0, +) / Double(topScores.count)
                return (person: item.person, score: average, hitCount: item.scores.count)
            }
            .filter { row in
                // hitCount 门槛按每人独立处理：只登记过 1 条样本的人也允许匹配，
                // 有多样本的人则要求至少命中 2 次（除非只有一个候选嵌入）。
                let requiredHits = min(
                    2,
                    max(1, sampleCountByPersonID[row.person.id, default: 1])
                )
                return row.hitCount >= requiredHits || candidates.count == 1
            }
            .sorted { left, right in
                if left.score == right.score {
                    return left.hitCount > right.hitCount
                }
                return left.score > right.score
            }
        guard let best = ranked.first else {
            return nil
        }
        // 只有一个匹配到的候选人时，不再要求 leadMargin。
        if ranked.count > 1,
           best.score - ranked[1].score < VoiceprintMatchingPolicy.minimumLeadMargin {
            return nil
        }
        return (best.person, best.score)
    }

    private static func orderedSpeakerKeys(turns: [DiarizationTurn]) -> [String] {
        var firstStartByKey: [String: Int] = [:]
        for turn in turns {
            firstStartByKey[turn.speakerKey] = min(firstStartByKey[turn.speakerKey] ?? turn.startMs, turn.startMs)
        }
        return firstStartByKey.keys.sorted { left, right in
            let leftStart = firstStartByKey[left] ?? Int.max
            let rightStart = firstStartByKey[right] ?? Int.max
            if leftStart == rightStart {
                return left < right
            }
            return leftStart < rightStart
        }
    }
}
