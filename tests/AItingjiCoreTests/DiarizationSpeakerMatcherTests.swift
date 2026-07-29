import AItingjiCore
import Testing

@Test
func diarizationSpeakerMatcherPreservesManualMappingOverAutomaticResult() {
    let manual = DiarizationSpeakerMapping(
        meetingID: "meeting-1",
        speakerKey: "microphone:SPEAKER_00",
        speakerLabel: "李四",
        personID: "person-li",
        personName: "李四",
        confidence: 1,
        isManual: true
    )
    let automatic = [
        DiarizationSpeakerMapping(
            meetingID: "meeting-1",
            speakerKey: "microphone:SPEAKER_00",
            speakerLabel: "张三",
            personID: "person-zhang",
            personName: "张三",
            confidence: 0.9
        ),
        DiarizationSpeakerMapping(
            meetingID: "meeting-1",
            speakerKey: "computer:SPEAKER_00",
            speakerLabel: "王五"
        )
    ]

    let merged = DiarizationSpeakerMatcher.preservingManualMappings(
        existing: [manual],
        automatic: automatic
    )

    #expect(merged.map(\.speakerLabel) == ["李四", "王五"])
    #expect(merged[0].isManual)
}

@Test
func diarizationSpeakerMatcherMapsKnownClusterToPersonName() {
    let people = [
        VoiceprintPerson(id: "person-zhang", displayName: "张三", threshold: 0.82)
    ]
    let samples = [
        VoiceprintSample(
            id: "sample-zhang-1",
            personID: "person-zhang",
            embedding: [1, 0, 0],
            durationMs: 3_000,
            qualityScore: 0.95
        )
    ]
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 2_000, speakerKey: "SPEAKER_00", confidence: 0.9)
    ]

    let mappings = DiarizationSpeakerMatcher.buildMappings(
        meetingID: "meeting-1",
        turns: turns,
        embeddingsBySpeakerKey: [
            "SPEAKER_00": VoiceprintResult(embedding: [1, 0, 0], confidence: 0.9)
        ],
        people: people,
        samples: samples
    )

    #expect(mappings.count == 1)
    #expect(mappings[0].speakerLabel == "张三")
    #expect(mappings[0].personID == "person-zhang")
    #expect(mappings[0].personName == "张三")
}

@Test
func diarizationSpeakerMatcherKeepsDifferentUnknownClustersSeparate() {
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 2_000, speakerKey: "SPEAKER_00", confidence: 0.9),
        DiarizationTurn(startMs: 2_000, endMs: 4_000, speakerKey: "SPEAKER_01", confidence: 0.9),
        DiarizationTurn(startMs: 4_000, endMs: 6_000, speakerKey: "SPEAKER_00", confidence: 0.9)
    ]

    let mappings = DiarizationSpeakerMatcher.buildMappings(
        meetingID: "meeting-1",
        turns: turns,
        embeddingsBySpeakerKey: [
            "SPEAKER_00": VoiceprintResult(embedding: [1, 0, 0], confidence: 0.9),
            "SPEAKER_01": VoiceprintResult(embedding: [0, 1, 0], confidence: 0.9)
        ],
        people: [],
        samples: []
    )

    #expect(mappings.map(\.speakerKey) == ["SPEAKER_00", "SPEAKER_01"])
    #expect(mappings.map(\.speakerLabel) == ["未知发言人 1", "未知发言人 2"])
}

@Test
func diarizationSpeakerMatcherDoesNotMergeUnknownClustersBySimilarEmbedding() {
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 2_000, speakerKey: "SPEAKER_00", confidence: 0.9),
        DiarizationTurn(startMs: 2_000, endMs: 4_000, speakerKey: "SPEAKER_01", confidence: 0.9)
    ]

    let mappings = DiarizationSpeakerMatcher.buildMappings(
        meetingID: "meeting-1",
        turns: turns,
        embeddingsBySpeakerKey: [
            "SPEAKER_00": VoiceprintResult(embedding: [1, 0, 0], confidence: 0.9),
            "SPEAKER_01": VoiceprintResult(embedding: [0.999, 0.001, 0], confidence: 0.9)
        ],
        people: [],
        samples: []
    )

    #expect(mappings.map(\.speakerLabel) == ["未知发言人 1", "未知发言人 2"])
}

@Test
func diarizationSpeakerMatcherUsesLongestValidTurnForEmbeddingWindow() {
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 300, speakerKey: "SPEAKER_00", confidence: 0.99),
        DiarizationTurn(startMs: 1_000, endMs: 4_000, speakerKey: "SPEAKER_00", confidence: 0.8),
        DiarizationTurn(startMs: 5_000, endMs: 6_200, speakerKey: "SPEAKER_00", confidence: 0.95)
    ]

    let window = DiarizationSpeakerMatcher.bestEmbeddingWindow(
        for: "SPEAKER_00",
        turns: turns,
        minimumDurationMs: 800
    )

    #expect(window?.startMs == 1_000)
    #expect(window?.endMs == 4_000)
}

@Test
func diarizationSpeakerMatcherUsesMultipleWindowsForStableKnownMatch() {
    let people = [
        VoiceprintPerson(id: "person-zhang", displayName: "张三", threshold: 0.82)
    ]
    let samples = [
        VoiceprintSample(
            id: "sample-zhang-1",
            personID: "person-zhang",
            embedding: [1, 0, 0],
            durationMs: 3_000,
            qualityScore: 0.95
        )
    ]
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 2_000, speakerKey: "SPEAKER_00", confidence: 0.9)
    ]

    let mappings = DiarizationSpeakerMatcher.buildMappings(
        meetingID: "meeting-1",
        turns: turns,
        embeddingCandidatesBySpeakerKey: [
            "SPEAKER_00": [
                VoiceprintResult(embedding: [0, 1, 0], confidence: 0.1),
                VoiceprintResult(embedding: [1, 0, 0], confidence: 0.95),
                VoiceprintResult(embedding: [0.98, 0.02, 0], confidence: 0.9)
            ]
        ],
        people: people,
        samples: samples
    )

    #expect(mappings.first?.speakerLabel == "张三")
    #expect(mappings.first?.personID == "person-zhang")
}

@Test
func diarizationSpeakerMatcherUsesFullRecordingWindowVotesInsteadOfAveragingPollutedEmbedding() {
    let people = [
        VoiceprintPerson(id: "person-zhang", displayName: "张三", threshold: 0.82)
    ]
    let samples = [
        VoiceprintSample(
            id: "sample-zhang-1",
            personID: "person-zhang",
            embedding: [1, 0, 0],
            durationMs: 3_000,
            qualityScore: 0.95
        )
    ]
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 2_000, speakerKey: "SPEAKER_00", confidence: 0.9),
        DiarizationTurn(startMs: 30_000, endMs: 34_000, speakerKey: "SPEAKER_00", confidence: 0.9),
        DiarizationTurn(startMs: 90_000, endMs: 95_000, speakerKey: "SPEAKER_00", confidence: 0.9)
    ]

    let mappings = DiarizationSpeakerMatcher.buildMappings(
        meetingID: "meeting-1",
        turns: turns,
        embeddingCandidatesBySpeakerKey: [
            "SPEAKER_00": [
                VoiceprintResult(embedding: [0, 1, 0], confidence: 0.95),
                VoiceprintResult(embedding: [1, 0, 0], confidence: 0.95),
                VoiceprintResult(embedding: [0.99, 0.01, 0], confidence: 0.9)
            ]
        ],
        people: people,
        samples: samples
    )

    #expect(mappings.first?.speakerLabel == "张三")
    #expect(mappings.first?.personID == "person-zhang")
}

@Test
func diarizationSpeakerMatcherRejectsCloseKnownCandidates() {
    let people = [
        VoiceprintPerson(id: "person-a", displayName: "甲", threshold: 0.82),
        VoiceprintPerson(id: "person-b", displayName: "乙", threshold: 0.82)
    ]
    let samples = [
        VoiceprintSample(id: "sample-a", personID: "person-a", embedding: [1, 0, 0], qualityScore: 0.95),
        VoiceprintSample(id: "sample-b", personID: "person-b", embedding: [0.999, 0.04, 0], qualityScore: 0.95)
    ]
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 2_000, speakerKey: "SPEAKER_00", confidence: 0.9)
    ]

    let mappings = DiarizationSpeakerMatcher.buildMappings(
        meetingID: "meeting-1",
        turns: turns,
        embeddingsBySpeakerKey: [
            "SPEAKER_00": VoiceprintResult(embedding: [1, 0, 0], confidence: 0.9)
        ],
        people: people,
        samples: samples
    )

    #expect(mappings.first?.speakerLabel == "未知发言人 1")
    #expect(mappings.first?.personID == nil)
}

@Test
func diarizationSpeakerMatcherKeepsUnknownWhenEmbeddingFails() {
    let turns = [
        DiarizationTurn(startMs: 0, endMs: 2_000, speakerKey: "SPEAKER_00", confidence: 0.9)
    ]

    let mappings = DiarizationSpeakerMatcher.buildMappings(
        meetingID: "meeting-1",
        turns: turns,
        embeddingCandidatesBySpeakerKey: ["SPEAKER_00": []],
        people: [VoiceprintPerson(id: "person-a", displayName: "甲", threshold: 0.82)],
        samples: [VoiceprintSample(id: "sample-a", personID: "person-a", embedding: [1, 0, 0], qualityScore: 0.95)]
    )

    #expect(mappings.first?.speakerLabel == "未知发言人 1")
    #expect(mappings.first?.personID == nil)
}
