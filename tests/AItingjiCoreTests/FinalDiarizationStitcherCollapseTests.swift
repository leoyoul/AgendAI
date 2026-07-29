import AItingjiCore
import Testing

@Test
func stitcherAutoCollapsesTwoClustersWithoutSpeakerCountHint() {
    // 5 个来自不同窗口的 local speaker：
    // - 前 3 个 embedding 都靠近 (1,0,0)（同人 A）
    // - 后 2 个都靠近 (0,1,0)（同人 B）
    // 完全不告诉 stitcher 有几个人；它应该自动收敛到 2 个 global speaker。
    let windows: [FinalDiarizationWindow] = (0..<5).map { i in
        FinalDiarizationWindow(index: i, startMs: i * 2_000, endMs: i * 2_000 + 1_500)
    }
    let turns = windows.map { window in
        WindowedDiarizationTurn(
            window: window,
            turn: DiarizationTurn(
                startMs: window.startMs,
                endMs: window.endMs,
                speakerKey: "SPEAKER_00",
                confidence: 0.9
            )
        )
    }
    let embeddings: [String: VoiceprintResult] = [
        "0:SPEAKER_00": VoiceprintResult(embedding: [1.0, 0.0, 0.0], confidence: 0.9),
        "1:SPEAKER_00": VoiceprintResult(embedding: [0.99, 0.14, 0.0], confidence: 0.9),
        "2:SPEAKER_00": VoiceprintResult(embedding: [0.98, 0.20, 0.0], confidence: 0.9),
        "3:SPEAKER_00": VoiceprintResult(embedding: [0.0, 1.0, 0.0], confidence: 0.9),
        "4:SPEAKER_00": VoiceprintResult(embedding: [0.1, 0.99, 0.0], confidence: 0.9)
    ]

    let stitched = FinalDiarizationWindowStitcher.stitch(
        windowedTurns: turns,
        embeddingsByLocalSpeakerKey: embeddings
    )
    let uniqueKeys = Set(stitched.map(\DiarizationTurn.speakerKey))
    #expect(uniqueKeys.count == 2, "expected 2 speakers, got \(uniqueKeys.count): \(uniqueKeys)")
}

@Test
func stitcherKeepsAllSpeakersWhenEmbeddingsAreClearlyDistinct() {
    // 4 个显著不同的说话人 embedding（互相接近正交），
    // 无论算法怎么想收敛都不能强行合并。
    let windows: [FinalDiarizationWindow] = (0..<4).map { i in
        FinalDiarizationWindow(index: i, startMs: i * 2_000, endMs: i * 2_000 + 1_500)
    }
    let turns = windows.map { window in
        WindowedDiarizationTurn(
            window: window,
            turn: DiarizationTurn(
                startMs: window.startMs,
                endMs: window.endMs,
                speakerKey: "SPEAKER_00",
                confidence: 0.9
            )
        )
    }
    let embeddings: [String: VoiceprintResult] = [
        "0:SPEAKER_00": VoiceprintResult(embedding: [1, 0, 0, 0], confidence: 0.9),
        "1:SPEAKER_00": VoiceprintResult(embedding: [0, 1, 0, 0], confidence: 0.9),
        "2:SPEAKER_00": VoiceprintResult(embedding: [0, 0, 1, 0], confidence: 0.9),
        "3:SPEAKER_00": VoiceprintResult(embedding: [0, 0, 0, 1], confidence: 0.9)
    ]

    let stitched = FinalDiarizationWindowStitcher.stitch(
        windowedTurns: turns,
        embeddingsByLocalSpeakerKey: embeddings
    )
    let uniqueKeys = Set(stitched.map(\DiarizationTurn.speakerKey))
    #expect(uniqueKeys.count == 4)
}

@Test
func stitcherCollapsesEightVeryCloseEmbeddingsIntoOneSpeaker() {
    // 8 个几乎相同的 embedding — 明显同一个人在 8 个窗口。
    // 应该被拟合成 1 人，不需要外部提示"最多 6 人"。
    let windows: [FinalDiarizationWindow] = (0..<8).map { i in
        FinalDiarizationWindow(index: i, startMs: i * 2_000, endMs: i * 2_000 + 1_500)
    }
    let turns = windows.map { window in
        WindowedDiarizationTurn(
            window: window,
            turn: DiarizationTurn(
                startMs: window.startMs,
                endMs: window.endMs,
                speakerKey: "SPEAKER_00",
                confidence: 0.9
            )
        )
    }
    var embeddings: [String: VoiceprintResult] = [:]
    for i in 0..<8 {
        embeddings["\(i):SPEAKER_00"] = VoiceprintResult(
            embedding: [1.0 - Double(i) * 0.001, Double(i) * 0.001, 0.0],
            confidence: 0.9
        )
    }

    let stitched = FinalDiarizationWindowStitcher.stitch(
        windowedTurns: turns,
        embeddingsByLocalSpeakerKey: embeddings
    )
    let uniqueKeys = Set(stitched.map(\DiarizationTurn.speakerKey))
    #expect(uniqueKeys.count == 1)
}
