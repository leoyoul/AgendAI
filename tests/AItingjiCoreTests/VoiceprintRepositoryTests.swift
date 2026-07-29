import AItingjiCore
import Foundation
import Testing

@Test
func voiceprintSampleRepositoryPersistsSamplesAcrossDatabaseReopen() throws {
    let path = temporaryVoiceprintDatabasePath("samples")

    do {
        let database = try Database(path: path)
        try database.migrate()
        try PeopleRepository(database: database).create(
            VoiceprintPerson(id: "person-zhang", displayName: "张三", threshold: 0.9)
        )
        try VoiceprintSampleRepository(database: database).upsert(
            VoiceprintSample(
                id: "sample-zhang-1",
                personID: "person-zhang",
                sourceMeetingID: "meeting-1",
                sourceSegmentID: "segment-1",
                embedding: [1, 0, 0],
                audioRef: "segment://segment-1",
                durationMs: 3000,
                qualityScore: 0.92,
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        database.close()
    }

    do {
        let database = try Database(path: path)
        try database.migrate()
        let samples = try VoiceprintSampleRepository(database: database).list()

        #expect(samples.count == 1)
        #expect(samples[0].personID == "person-zhang")
        #expect(samples[0].embedding == [1, 0, 0])
        #expect(samples[0].durationMs == 3000)
        #expect(samples[0].qualityScore == 0.92)
        database.close()
    }

    try? FileManager.default.removeItem(atPath: path)
}

@Test
func speakerResolverPrefersKnownVoiceprintBeforeUnknownMeetingLabel() {
    let people = [
        VoiceprintPerson(id: "person-zhang", displayName: "张三", threshold: 0.9)
    ]
    let samples = [
        VoiceprintSample(id: "sample-zhang-1", personID: "person-zhang", embedding: [1, 0, 0])
    ]
    var resolver = SpeakerResolver(people: people, samples: samples, unknownThreshold: 0.85)

    let known = resolver.resolve(embedding: [0.99, 0.01, 0], confidence: 0.87)
    let unknown = resolver.resolve(embedding: [0, 1, 0], confidence: 0.44)
    let sameUnknown = resolver.resolve(embedding: [0, 0.99, 0.01], confidence: 0.48)

    #expect(known.label == "张三")
    #expect(known.personID == "person-zhang")
    #expect(known.personName == "张三")
    #expect(known.confidence >= 0.9)
    #expect(unknown.label == "未知发言人 1")
    #expect(unknown.personID == nil)
    #expect(sameUnknown.label == "未知发言人 1")
}

@Test
func speakerResolverRejectsKnownMatchWhenLeadMarginIsTooSmall() {
    let people = [
        VoiceprintPerson(id: "person-zhang", displayName: "张三", threshold: 0.9),
        VoiceprintPerson(id: "person-li", displayName: "李四", threshold: 0.9)
    ]
    let samples = [
        VoiceprintSample(id: "sample-zhang-1", personID: "person-zhang", embedding: [1, 0, 0], qualityScore: 0.95),
        VoiceprintSample(id: "sample-li-1", personID: "person-li", embedding: [0.99, 0.01, 0], qualityScore: 0.95)
    ]
    var resolver = SpeakerResolver(people: people, samples: samples, unknownThreshold: 0.85)

    let resolution = resolver.resolve(embedding: [0.995, 0.005, 0], confidence: 0.75)

    #expect(resolution.label == "未知发言人 1")
    #expect(resolution.personID == nil)
}

@Test
func speakerResolverIgnoresLowQualityKnownSamples() {
    let people = [
        VoiceprintPerson(id: "person-zhang", displayName: "张三", threshold: 0.9)
    ]
    let samples = [
        VoiceprintSample(id: "sample-zhang-low", personID: "person-zhang", embedding: [1, 0, 0], qualityScore: 0.2)
    ]
    var resolver = SpeakerResolver(people: people, samples: samples, unknownThreshold: 0.85)

    let resolution = resolver.resolve(embedding: [1, 0, 0], confidence: 0.75)

    #expect(resolution.label == "未知发言人 1")
    #expect(resolution.personID == nil)
}

@Test
func speakerResolverCanAllocateUnknownLabelsWithoutEmbedding() {
    var resolver = SpeakerResolver(people: [], samples: [], unknownThreshold: 0.85)

    let first = resolver.allocateUnknown(confidence: 0)
    let second = resolver.allocateUnknown(confidence: 0)

    #expect(first.label == "未知发言人 1")
    #expect(second.label == "未知发言人 2")
}

@Test
func speakerResolverReusesTemporaryUnknownLabelBeforeFinalDiarization() {
    var resolver = SpeakerResolver(people: [], samples: [], unknownThreshold: 0.85)

    let first = resolver.allocateTemporaryUnknown(confidence: 0.3)
    let second = resolver.allocateTemporaryUnknown(confidence: 0.3)

    #expect(first.label == "未知发言人 1")
    #expect(second.label == "未知发言人 1")
}

@Test
func speakerResolverDoesNotReuseUnknownIndexAcrossEmbeddingAndNoEmbeddingPaths() {
    var resolver = SpeakerResolver(people: [], samples: [], unknownThreshold: 0.85)

    let first = resolver.resolve(embedding: [1, 0, 0], confidence: 0.4)
    let second = resolver.allocateUnknown(confidence: 0)

    #expect(first.label == "未知发言人 1")
    #expect(second.label == "未知发言人 2")
}

@Test
func defaultVoiceprintThresholdBalancesRecognitionAndFalseMatches() {
    let person = VoiceprintPerson(id: "person-default", displayName: "默认阈值")

    #expect(person.threshold == 0.82)
}

@Test
func defaultUnknownSpeakerThresholdAllowsLiveUtteranceReuse() {
    let assigner = UnknownSpeakerAssigner()

    #expect(assigner.threshold == 0.68)
}

private func temporaryVoiceprintDatabasePath(_ name: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("AItingji-\(UUID().uuidString)-\(name)")
        .appendingPathExtension("sqlite")
        .path
}
