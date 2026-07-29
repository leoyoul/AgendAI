import Foundation

public enum VoiceprintEnrollmentError: Error, Equatable, Sendable {
    case emptyEmbedding
    case lowQualitySample
}

public enum VoiceprintEnrollment {
    public static func makeSample(
        person: VoiceprintPerson,
        segment: TranscriptSegment,
        embedding: [Double],
        confidence: Double,
        createdAt: Date = Date(),
        manualEnrollment: Bool = false
    ) throws -> VoiceprintSample {
        guard !embedding.isEmpty else {
            throw VoiceprintEnrollmentError.emptyEmbedding
        }
        let durationMs = max(0, segment.endMs - segment.startMs)
        // 手动改名触发的入库信任用户，只校验时长和向量非零，不再要求 ASR/声纹侧 confidence。
        let confidenceOK = manualEnrollment || confidence >= VoiceprintMatchingPolicy.minimumEnrollmentConfidence
        guard durationMs >= VoiceprintMatchingPolicy.minimumEnrollmentDurationMs,
              confidenceOK,
              vectorNorm(embedding) > 0.000001 else {
            throw VoiceprintEnrollmentError.lowQualitySample
        }

        // 手动入库时给一个不低于 0.65 的质量分，避免后续被 `isKnownSampleEligible` 排除。
        let qualityScore: Double = manualEnrollment
            ? max(VoiceprintMatchingPolicy.minimumKnownSampleQuality, min(1, confidence))
            : max(0, min(1, confidence))

        return VoiceprintSample(
            id: "vp-\(person.id)-\(segment.id)",
            personID: person.id,
            sourceMeetingID: segment.meetingID,
            sourceSegmentID: segment.id,
            embedding: embedding,
            audioRef: "segment://\(segment.id)",
            durationMs: durationMs,
            qualityScore: qualityScore,
            createdAt: createdAt
        )
    }

    private static func vectorNorm(_ embedding: [Double]) -> Double {
        sqrt(embedding.reduce(0) { $0 + $1 * $1 })
    }
}
