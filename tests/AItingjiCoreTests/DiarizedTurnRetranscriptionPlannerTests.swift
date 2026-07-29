import AItingjiCore
import Testing

@Test
func diarizedTurnRetranscriptionPlannerKeepsNonManualPartsAroundManualSegment() {
    let turns = [
        DiarizationTurn(startMs: 23_925, endMs: 35_097, speakerKey: "SPEAKER_01", confidence: 0.9)
    ]
    let manual = [
        TranscriptSegment(
            id: "manual",
            meetingID: "m1",
            startMs: 24_964,
            endMs: 27_964,
            speakerLabel: "张三",
            isManual: true
        )
    ]

    let planned = DiarizedTurnRetranscriptionPlanner.plan(turns: turns, manualSegments: manual)

    #expect(planned.map(\.startMs) == [23_925, 27_964])
    #expect(planned.map(\.endMs) == [24_964, 35_097])
}

@Test
func diarizedTurnRetranscriptionPlannerMergesNearbyTurnsFromSameSpeaker() {
    let turns = [
        DiarizationTurn(startMs: 1_000, endMs: 2_000, speakerKey: "A", confidence: 0.8),
        DiarizationTurn(startMs: 2_300, endMs: 3_000, speakerKey: "A", confidence: 0.9),
        DiarizationTurn(startMs: 3_300, endMs: 4_100, speakerKey: "B", confidence: 0.7)
    ]

    let planned = DiarizedTurnRetranscriptionPlanner.plan(turns: turns, manualSegments: [])

    #expect(planned.map(\.speakerKey) == ["A", "B"])
    #expect(planned.map(\.startMs) == [1_000, 3_300])
    #expect(planned.map(\.endMs) == [3_000, 4_100])
}
