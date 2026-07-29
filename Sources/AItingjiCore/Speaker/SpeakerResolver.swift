import Foundation

public struct SpeakerResolution: Equatable, Sendable {
    public var label: String
    public var autoLabel: String
    public var personID: String?
    public var personName: String?
    public var confidence: Double

    public init(
        label: String,
        autoLabel: String,
        personID: String? = nil,
        personName: String? = nil,
        confidence: Double
    ) {
        self.label = label
        self.autoLabel = autoLabel
        self.personID = personID
        self.personName = personName
        self.confidence = confidence
    }
}

public enum VoiceprintMatchingPolicy {
    /// 每个 person 未显式指定阈值时的默认基线。0.82 面向长片段、多样本的稳态场景。
    public static let minimumPersonThreshold = 0.82
    /// safeThreshold 的下限：实测 ECAPA-TDNN 同人余弦通常落在 0.72~0.90，
    /// 允许用户把 person.threshold 手动调到 0.72 以避免过严导致真人被判为陌生。
    public static let absoluteMinimumThreshold = 0.72
    public static let minimumLeadMargin = 0.04
    public static let minimumKnownSampleQuality = 0.65
    public static let minimumRecognitionConfidence = 0.65
    public static let minimumEnrollmentDurationMs = 2_000
    public static let minimumEnrollmentConfidence = 0.65

    public static func safeThreshold(for person: VoiceprintPerson) -> Double {
        max(person.threshold, absoluteMinimumThreshold)
    }

    public static func isKnownSampleEligible(_ sample: VoiceprintSample) -> Bool {
        sample.qualityScore == 0 || sample.qualityScore >= minimumKnownSampleQuality
    }
}

public struct SpeakerResolver: Sendable {
    private let peopleByID: [String: VoiceprintPerson]
    private let samples: [VoiceprintSample]
    private var unknownAssigner: UnknownSpeakerAssigner
    private var nextEmbeddinglessUnknownIndex = 1
    private var temporaryUnknownLabel: String?

    public init(
        people: [VoiceprintPerson],
        samples: [VoiceprintSample],
        unknownThreshold: Double = 0.68
    ) {
        self.peopleByID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        self.samples = samples
        self.unknownAssigner = UnknownSpeakerAssigner(threshold: unknownThreshold)
    }

    public mutating func resolve(embedding: [Double], confidence: Double) -> SpeakerResolution {
        if confidence >= VoiceprintMatchingPolicy.minimumRecognitionConfidence,
           let known = bestKnownMatch(for: embedding) {
            return SpeakerResolution(
                label: known.person.displayName,
                autoLabel: known.person.displayName,
                personID: known.person.id,
                personName: known.person.displayName,
                confidence: min(1, max(confidence, known.score))
            )
        }

        let unknown = unknownAssigner.assign(embedding: embedding)
        nextEmbeddinglessUnknownIndex = max(nextEmbeddinglessUnknownIndex, unknownAssigner.speakers.count + 1)
        return SpeakerResolution(
            label: unknown.label,
            autoLabel: unknown.label,
            confidence: confidence
        )
    }

    public mutating func allocateUnknown(confidence: Double) -> SpeakerResolution {
        let label = "未知发言人 \(nextEmbeddinglessUnknownIndex)"
        nextEmbeddinglessUnknownIndex += 1
        return SpeakerResolution(
            label: label,
            autoLabel: label,
            confidence: confidence
        )
    }

    public mutating func allocateTemporaryUnknown(confidence: Double) -> SpeakerResolution {
        let label: String
        if let existing = temporaryUnknownLabel {
            label = existing
        } else {
            label = "未知发言人 \(nextEmbeddinglessUnknownIndex)"
            temporaryUnknownLabel = label
            nextEmbeddinglessUnknownIndex += 1
        }
        return SpeakerResolution(
            label: label,
            autoLabel: label,
            confidence: confidence
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

        let candidates = bestByPersonID.values.sorted { left, right in
            left.score > right.score
        }

        guard let best = candidates.first else {
            return nil
        }

        if candidates.count > 1,
           best.score - candidates[1].score < VoiceprintMatchingPolicy.minimumLeadMargin {
            return nil
        }

        return best
    }
}
