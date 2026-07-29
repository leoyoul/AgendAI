import AItingjiCore
import Testing

@Test
func cosineSimilarityScoresIdenticalVectorsAsOne() {
    #expect(cosineSimilarity([1, 0, 0], [1, 0, 0]) == 1)
}

@Test
func unknownSpeakerAssignmentReusesSimilarVoice() {
    var assigner = UnknownSpeakerAssigner(threshold: 0.9)

    let first = assigner.assign(embedding: [1, 0, 0])
    let second = assigner.assign(embedding: [0.99, 0.01, 0])

    #expect(first.label == "未知发言人 1")
    #expect(second.label == "未知发言人 1")
    #expect(assigner.speakers.count == 1)
}

@Test
func unknownSpeakerAssignmentAllocatesNextLabelForNewVoice() {
    var assigner = UnknownSpeakerAssigner(threshold: 0.9)

    let first = assigner.assign(embedding: [1, 0, 0])
    let second = assigner.assign(embedding: [0, 1, 0])

    #expect(first.label == "未知发言人 1")
    #expect(second.label == "未知发言人 2")
    #expect(assigner.speakers.count == 2)
}

@Test
func unknownSpeakerAssignmentSmoothsAndReusesModeratelySimilarLiveVoice() {
    var assigner = UnknownSpeakerAssigner()

    let first = assigner.assign(embedding: [10, 0, 0])
    let second = assigner.assign(embedding: [0.7, 0.7, 0])
    let third = assigner.assign(embedding: [0.72, 0.69, 0])

    #expect(first.label == "未知发言人 1")
    #expect(second.label == "未知发言人 1")
    #expect(third.label == "未知发言人 1")
    #expect(assigner.speakers.count == 1)
}

@Test
func knownSpeakerAssignmentAcceptsPracticalSimilarityThreshold() {
    var resolver = SpeakerResolver(
        people: [VoiceprintPerson(id: "person-a", displayName: "甲", threshold: 0.82)],
        samples: [VoiceprintSample(id: "sample-a", personID: "person-a", embedding: [1, 0, 0], qualityScore: 0.95)]
    )

    let resolution = resolver.resolve(embedding: [0.84, 0.54, 0], confidence: 0.9)

    #expect(resolution.personID == "person-a")
    #expect(resolution.label == "甲")
}
