import AItingjiCore
import Testing

@Test
func finalDiarizationPlannerCoversLongAudioWithOverlappingWindows() {
    let windows = FinalDiarizationWindowPlanner.windows(
        audioDurationMs: 317_384,
        windowDurationMs: 90_000,
        overlapMs: 15_000
    )

    #expect(windows == [
        FinalDiarizationWindow(index: 0, startMs: 0, endMs: 90_000),
        FinalDiarizationWindow(index: 1, startMs: 75_000, endMs: 165_000),
        FinalDiarizationWindow(index: 2, startMs: 150_000, endMs: 240_000),
        FinalDiarizationWindow(index: 3, startMs: 225_000, endMs: 317_384)
    ])
}

@Test
func finalDiarizationPlannerUsesSingleWindowForShortAudio() {
    let windows = FinalDiarizationWindowPlanner.windows(
        audioDurationMs: 42_000,
        windowDurationMs: 90_000,
        overlapMs: 15_000
    )

    #expect(windows == [
        FinalDiarizationWindow(index: 0, startMs: 0, endMs: 42_000)
    ])
}

@Test
func finalDiarizationPlannerSplitsOverlapsAtMidpointsForAcceptedRegions() {
    let windows = FinalDiarizationWindowPlanner.windows(
        audioDurationMs: 317_384,
        windowDurationMs: 90_000,
        overlapMs: 15_000
    )

    let accepted = windows.map {
        FinalDiarizationWindowPlanner.acceptedRegion(for: $0, in: windows)
    }

    #expect(accepted == [
        FinalDiarizationWindow(index: 0, startMs: 0, endMs: 82_500),
        FinalDiarizationWindow(index: 1, startMs: 82_500, endMs: 157_500),
        FinalDiarizationWindow(index: 2, startMs: 157_500, endMs: 232_500),
        FinalDiarizationWindow(index: 3, startMs: 232_500, endMs: 317_384)
    ])
}

@Test
func finalDiarizationPlannerClipsTurnsToAcceptedRegion() {
    let window = FinalDiarizationWindow(index: 0, startMs: 0, endMs: 90_000)
    let accepted = FinalDiarizationWindow(index: 0, startMs: 0, endMs: 82_500)
    let turn = DiarizationTurn(startMs: 80_000, endMs: 90_000, speakerKey: "SPEAKER_00", confidence: 0.9)

    let clipped = FinalDiarizationWindowPlanner.clip(turn: turn, to: accepted)

    #expect(clipped == DiarizationTurn(startMs: 80_000, endMs: 82_500, speakerKey: "SPEAKER_00", confidence: 0.9))
    _ = window
}

@Test
func finalDiarizationSelectorPrefersMultiSpeakerWindowedTurnsOverCollapsedFullRun() {
    let fullTurns = [
        DiarizationTurn(startMs: 0, endMs: 60_000, speakerKey: "SPEAKER_00", confidence: 0.9)
    ]
    let windowedTurns = [
        DiarizationTurn(startMs: 0, endMs: 30_000, speakerKey: "SPEAKER_GLOBAL_01", confidence: 0.9),
        DiarizationTurn(startMs: 30_000, endMs: 60_000, speakerKey: "SPEAKER_GLOBAL_02", confidence: 0.9)
    ]

    let selected = FinalDiarizationTurnSelector.select(
        fullTurns: fullTurns,
        windowedTurns: windowedTurns,
        audioDurationMs: 60_000
    )

    #expect(selected.turns == windowedTurns)
    #expect(selected.source == .windowed)
}

@Test
func finalDiarizationSelectorAcceptsRealMeetingWindowedSpeechCoverage() {
    let fullTurns = [
        DiarizationTurn(startMs: 0, endMs: 100_000, speakerKey: "SPEAKER_00", confidence: 0.9)
    ]
    let windowedTurns = [
        DiarizationTurn(startMs: 0, endMs: 20_000, speakerKey: "SPEAKER_GLOBAL_01", confidence: 0.9),
        DiarizationTurn(startMs: 20_000, endMs: 43_000, speakerKey: "SPEAKER_GLOBAL_02", confidence: 0.9)
    ]

    let selected = FinalDiarizationTurnSelector.select(
        fullTurns: fullTurns,
        windowedTurns: windowedTurns,
        audioDurationMs: 100_000
    )

    #expect(selected.turns == windowedTurns)
    #expect(selected.source == .windowed)
}

@Test
func finalDiarizationSelectorKeepsFullRunWhenWindowedCoverageIsTooLow() {
    let fullTurns = [
        DiarizationTurn(startMs: 0, endMs: 60_000, speakerKey: "SPEAKER_00", confidence: 0.9)
    ]
    let windowedTurns = [
        DiarizationTurn(startMs: 0, endMs: 10_000, speakerKey: "SPEAKER_GLOBAL_01", confidence: 0.9),
        DiarizationTurn(startMs: 10_000, endMs: 20_000, speakerKey: "SPEAKER_GLOBAL_02", confidence: 0.9)
    ]

    let selected = FinalDiarizationTurnSelector.select(
        fullTurns: fullTurns,
        windowedTurns: windowedTurns,
        audioDurationMs: 60_000
    )

    #expect(selected.turns == fullTurns)
    #expect(selected.source == .full)
}

@Test
func finalDiarizationSelectorDoesNotDoubleCountOverlappingWindowedCoverage() {
    let fullTurns = [
        DiarizationTurn(startMs: 0, endMs: 100_000, speakerKey: "SPEAKER_00", confidence: 0.9)
    ]
    let windowedTurns = [
        DiarizationTurn(startMs: 0, endMs: 29_000, speakerKey: "SPEAKER_GLOBAL_01", confidence: 0.9),
        DiarizationTurn(startMs: 10_000, endMs: 39_000, speakerKey: "SPEAKER_GLOBAL_02", confidence: 0.9)
    ]

    let selected = FinalDiarizationTurnSelector.select(
        fullTurns: fullTurns,
        windowedTurns: windowedTurns,
        audioDurationMs: 100_000
    )

    #expect(selected.turns == fullTurns)
    #expect(selected.source == .full)
}

@Test
func finalDiarizationStitcherMergesAdjacentLocalSpeakersWithStrongEmbeddingEvidence() {
    let windowedTurns = [
        WindowedDiarizationTurn(
            window: FinalDiarizationWindow(index: 0, startMs: 0, endMs: 90_000),
            turn: DiarizationTurn(startMs: 10_000, endMs: 40_000, speakerKey: "SPEAKER_00", confidence: 0.9)
        ),
        WindowedDiarizationTurn(
            window: FinalDiarizationWindow(index: 1, startMs: 75_000, endMs: 165_000),
            turn: DiarizationTurn(startMs: 90_000, endMs: 120_000, speakerKey: "SPEAKER_01", confidence: 0.9)
        )
    ]
    let embeddings = [
        "0:SPEAKER_00": VoiceprintResult(embedding: [1, 0, 0], confidence: 0.95),
        "1:SPEAKER_01": VoiceprintResult(embedding: [0.99, 0.01, 0], confidence: 0.95)
    ]

    let stitched = FinalDiarizationWindowStitcher.stitch(
        windowedTurns: windowedTurns,
        embeddingsByLocalSpeakerKey: embeddings
    )

    #expect(stitched.map(\.speakerKey) == ["SPEAKER_GLOBAL_01", "SPEAKER_GLOBAL_01"])
}

@Test
func finalDiarizationStitcherKeepsDifferentLocalSpeakersSeparateWhenEvidenceIsWeak() {
    let windowedTurns = [
        WindowedDiarizationTurn(
            window: FinalDiarizationWindow(index: 0, startMs: 0, endMs: 90_000),
            turn: DiarizationTurn(startMs: 10_000, endMs: 40_000, speakerKey: "SPEAKER_00", confidence: 0.9)
        ),
        WindowedDiarizationTurn(
            window: FinalDiarizationWindow(index: 1, startMs: 75_000, endMs: 165_000),
            turn: DiarizationTurn(startMs: 90_000, endMs: 120_000, speakerKey: "SPEAKER_01", confidence: 0.9)
        )
    ]
    let embeddings = [
        "0:SPEAKER_00": VoiceprintResult(embedding: [1, 0, 0], confidence: 0.95),
        "1:SPEAKER_01": VoiceprintResult(embedding: [0, 1, 0], confidence: 0.95)
    ]

    let stitched = FinalDiarizationWindowStitcher.stitch(
        windowedTurns: windowedTurns,
        embeddingsByLocalSpeakerKey: embeddings
    )

    #expect(stitched.map(\.speakerKey) == ["SPEAKER_GLOBAL_01", "SPEAKER_GLOBAL_02"])
}

@Test
func finalDiarizationStitcherDoesNotMergeDifferentSpeakersFromSameWindow() {
    let sameWindow = FinalDiarizationWindow(index: 0, startMs: 0, endMs: 90_000)
    let windowedTurns = [
        WindowedDiarizationTurn(
            window: sameWindow,
            turn: DiarizationTurn(startMs: 10_000, endMs: 30_000, speakerKey: "SPEAKER_00", confidence: 0.9)
        ),
        WindowedDiarizationTurn(
            window: sameWindow,
            turn: DiarizationTurn(startMs: 30_000, endMs: 50_000, speakerKey: "SPEAKER_01", confidence: 0.9)
        )
    ]
    let embeddings = [
        "0:SPEAKER_00": VoiceprintResult(embedding: [1, 0, 0], confidence: 0.95),
        "0:SPEAKER_01": VoiceprintResult(embedding: [0.99, 0.01, 0], confidence: 0.95)
    ]

    let stitched = FinalDiarizationWindowStitcher.stitch(
        windowedTurns: windowedTurns,
        embeddingsByLocalSpeakerKey: embeddings
    )

    #expect(stitched.map(\.speakerKey) == ["SPEAKER_GLOBAL_01", "SPEAKER_GLOBAL_02"])
}
