import AItingjiCore
import Foundation
import Testing

@Test
func voiceprintEnrollmentCreatesSampleFromRenamedSegmentAndEmbedding() throws {
    let person = VoiceprintPerson(id: "person-wang", displayName: "王五")
    let segment = TranscriptSegment(
        id: "segment-1",
        meetingID: "meeting-1",
        startMs: 2_000,
        endMs: 6_500,
        speakerLabel: "王五",
        personID: person.id,
        personName: person.displayName,
        confidence: 0.73,
        rawText: "我们确认一下声纹补录。"
    )

    let sample = try VoiceprintEnrollment.makeSample(
        person: person,
        segment: segment,
        embedding: [0.1, 0.2, 0.3],
        confidence: 0.73,
        createdAt: Date(timeIntervalSince1970: 1_900_000_000)
    )

    #expect(sample.id == "vp-person-wang-segment-1")
    #expect(sample.personID == "person-wang")
    #expect(sample.sourceMeetingID == "meeting-1")
    #expect(sample.sourceSegmentID == "segment-1")
    #expect(sample.embedding == [0.1, 0.2, 0.3])
    #expect(sample.audioRef == "segment://segment-1")
    #expect(sample.durationMs == 4_500)
    #expect(sample.qualityScore == 0.73)
    #expect(sample.createdAt == Date(timeIntervalSince1970: 1_900_000_000))
}

@Test
func voiceprintEnrollmentRejectsEmptyEmbedding() throws {
    let person = VoiceprintPerson(id: "person-empty", displayName: "空样本")
    let segment = TranscriptSegment(
        id: "segment-empty",
        meetingID: "meeting-empty",
        startMs: 0,
        endMs: 1_000,
        speakerLabel: "空样本"
    )

    #expect(throws: VoiceprintEnrollmentError.emptyEmbedding) {
        _ = try VoiceprintEnrollment.makeSample(
            person: person,
            segment: segment,
            embedding: [],
            confidence: 0.5
        )
    }
}

@Test
func voiceprintEnrollmentRejectsLowQualitySegments() throws {
    let person = VoiceprintPerson(id: "person-short", displayName: "短样本")
    let shortSegment = TranscriptSegment(
        id: "segment-short",
        meetingID: "meeting-short",
        startMs: 0,
        endMs: 1_000,
        speakerLabel: "短样本"
    )

    #expect(throws: VoiceprintEnrollmentError.lowQualitySample) {
        _ = try VoiceprintEnrollment.makeSample(
            person: person,
            segment: shortSegment,
            embedding: [0.1, 0.2, 0.3],
            confidence: 0.9
        )
    }
}

@Test
func voiceprintEnrollmentAcceptsManualLowConfidenceRename() throws {
    // 用户手动改名场景：Live 段 confidence 一般只有 0.3~0.4，不该阻断入库。
    let person = VoiceprintPerson(id: "person-manual", displayName: "手动张三")
    let segment = TranscriptSegment(
        id: "segment-manual",
        meetingID: "meeting-manual",
        startMs: 0,
        endMs: 3_000,
        speakerLabel: "手动张三",
        personID: person.id,
        personName: person.displayName,
        confidence: 0.3
    )

    let sample = try VoiceprintEnrollment.makeSample(
        person: person,
        segment: segment,
        embedding: [0.1, 0.2, 0.3],
        confidence: 0.3,
        manualEnrollment: true
    )

    #expect(sample.personID == "person-manual")
    #expect(sample.qualityScore >= VoiceprintMatchingPolicy.minimumKnownSampleQuality)
}

@Test
func diarizationSpeakerMatcherMatchesSinglePersonWithSingleSample() {
    // 只有一条声纹样本的人员也应该能被匹配到（原实现要求 hitCount>=2）。
    let person = VoiceprintPerson(id: "p", displayName: "小明", threshold: 0.72)
    let sample = VoiceprintSample(
        id: "vp-p-1",
        personID: "p",
        sourceMeetingID: "m0",
        sourceSegmentID: "s0",
        embedding: [1.0, 0.0, 0.0],
        audioRef: "seg",
        durationMs: 3_000,
        qualityScore: 0.9,
        createdAt: Date()
    )
    let candidate = VoiceprintResult(
        embedding: [0.98, 0.19, 0.0],
        confidence: 0.9
    )
    let mappings = DiarizationSpeakerMatcher.buildMappings(
        meetingID: "m1",
        turns: [DiarizationTurn(startMs: 0, endMs: 2_000, speakerKey: "SPEAKER_00", confidence: 0.9)],
        embeddingCandidatesBySpeakerKey: ["SPEAKER_00": [candidate]],
        people: [person],
        samples: [sample]
    )
    #expect(mappings.first?.personID == "p")
}
