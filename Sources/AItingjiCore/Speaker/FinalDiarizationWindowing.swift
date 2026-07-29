import Foundation

public struct FinalDiarizationWindow: Equatable, Sendable {
    public var index: Int
    public var startMs: Int
    public var endMs: Int

    public init(index: Int, startMs: Int, endMs: Int) {
        self.index = index
        self.startMs = startMs
        self.endMs = endMs
    }
}

public struct WindowedDiarizationTurn: Equatable, Sendable {
    public var window: FinalDiarizationWindow
    public var turn: DiarizationTurn

    public init(window: FinalDiarizationWindow, turn: DiarizationTurn) {
        self.window = window
        self.turn = turn
    }
}

public enum FinalDiarizationWindowPlanner {
    public static let defaultWindowDurationMs = 90_000
    public static let defaultOverlapMs = 15_000
    public static let minimumTailDurationMs = 30_000

    public static func windows(
        audioDurationMs: Int,
        windowDurationMs: Int = defaultWindowDurationMs,
        overlapMs: Int = defaultOverlapMs,
        minimumTailDurationMs: Int = minimumTailDurationMs
    ) -> [FinalDiarizationWindow] {
        guard audioDurationMs > 0 else {
            return []
        }
        guard windowDurationMs > 0, overlapMs >= 0, overlapMs < windowDurationMs else {
            return [FinalDiarizationWindow(index: 0, startMs: 0, endMs: audioDurationMs)]
        }
        guard audioDurationMs > windowDurationMs else {
            return [FinalDiarizationWindow(index: 0, startMs: 0, endMs: audioDurationMs)]
        }

        let stepMs = windowDurationMs - overlapMs
        var starts: [Int] = []
        var cursor = 0
        while cursor + windowDurationMs < audioDurationMs {
            starts.append(cursor)
            cursor += stepMs
        }

        let tailDurationMs = audioDurationMs - cursor
        if tailDurationMs >= minimumTailDurationMs || starts.isEmpty {
            starts.append(cursor)
        }

        var windows = starts.enumerated().map { index, startMs in
            FinalDiarizationWindow(
                index: index,
                startMs: startMs,
                endMs: min(audioDurationMs, startMs + windowDurationMs)
            )
        }
        if let last = windows.indices.last, windows[last].endMs < audioDurationMs {
            windows[last].endMs = audioDurationMs
        }
        return windows
    }

    public static func acceptedRegion(
        for window: FinalDiarizationWindow,
        in windows: [FinalDiarizationWindow]
    ) -> FinalDiarizationWindow {
        let sorted = windows.sorted { $0.startMs < $1.startMs }
        guard let index = sorted.firstIndex(of: window) else {
            return window
        }
        var startMs = window.startMs
        var endMs = window.endMs
        if index > 0 {
            let previous = sorted[index - 1]
            startMs = midpoint(previous.endMs, window.startMs)
        }
        if index + 1 < sorted.count {
            let next = sorted[index + 1]
            endMs = midpoint(window.endMs, next.startMs)
        }
        return FinalDiarizationWindow(
            index: window.index,
            startMs: max(window.startMs, startMs),
            endMs: min(window.endMs, endMs)
        )
    }

    public static func clip(turn: DiarizationTurn, to region: FinalDiarizationWindow) -> DiarizationTurn? {
        let startMs = max(turn.startMs, region.startMs)
        let endMs = min(turn.endMs, region.endMs)
        guard endMs > startMs else {
            return nil
        }
        return DiarizationTurn(
            startMs: startMs,
            endMs: endMs,
            speakerKey: turn.speakerKey,
            confidence: turn.confidence
        )
    }

    private static func midpoint(_ left: Int, _ right: Int) -> Int {
        min(left, right) + abs(left - right) / 2
    }
}

public enum FinalDiarizationTurnSource: Equatable, Sendable {
    case full
    case windowed
}

public struct FinalDiarizationTurnSelection: Equatable, Sendable {
    public var turns: [DiarizationTurn]
    public var source: FinalDiarizationTurnSource

    public init(turns: [DiarizationTurn], source: FinalDiarizationTurnSource) {
        self.turns = turns
        self.source = source
    }
}

public enum FinalDiarizationTurnSelector {
    public static let minimumWindowedCoverageRatio = 0.40

    public static func select(
        fullTurns: [DiarizationTurn],
        windowedTurns: [DiarizationTurn],
        audioDurationMs: Int,
        minimumWindowedCoverageRatio: Double = minimumWindowedCoverageRatio
    ) -> FinalDiarizationTurnSelection {
        // 拼接侧已经用 gap-based 层次合并把 ECAPA 震荡切多的 speaker 收敛过一遍，
        // 所以这里可以放心用 windowed 结果——只要它覆盖率够、比 full 多识别到人。
        let fullSpeakerCount = speakerCount(fullTurns)
        let windowedSpeakerCount = speakerCount(windowedTurns)
        let windowedCoverage = coverageRatio(turns: windowedTurns, audioDurationMs: audioDurationMs)

        if windowedSpeakerCount > max(1, fullSpeakerCount),
           windowedCoverage >= minimumWindowedCoverageRatio {
            return FinalDiarizationTurnSelection(turns: normalized(windowedTurns), source: .windowed)
        }
        return FinalDiarizationTurnSelection(turns: normalized(fullTurns), source: .full)
    }

    private static func speakerCount(_ turns: [DiarizationTurn]) -> Int {
        Set(turns.map(\.speakerKey)).count
    }

    private static func coverageRatio(turns: [DiarizationTurn], audioDurationMs: Int) -> Double {
        guard audioDurationMs > 0 else {
            return 0
        }
        let durationMs = mergedDurationMs(turns: normalized(turns))
        return min(1, Double(durationMs) / Double(audioDurationMs))
    }

    private static func mergedDurationMs(turns: [DiarizationTurn]) -> Int {
        var merged: [(startMs: Int, endMs: Int)] = []
        for turn in turns {
            guard var last = merged.popLast() else {
                merged.append((turn.startMs, turn.endMs))
                continue
            }
            if turn.startMs <= last.endMs {
                last.endMs = max(last.endMs, turn.endMs)
                merged.append(last)
            } else {
                merged.append(last)
                merged.append((turn.startMs, turn.endMs))
            }
        }
        return merged.reduce(0) { total, interval in
            total + max(0, interval.endMs - interval.startMs)
        }
    }

    private static func normalized(_ turns: [DiarizationTurn]) -> [DiarizationTurn] {
        turns
            .filter { $0.endMs > $0.startMs }
            .sorted { left, right in
                if left.startMs == right.startMs {
                    return left.endMs < right.endMs
                }
                return left.startMs < right.startMs
            }
    }
}

public enum FinalDiarizationWindowStitcher {
    /// 第一轮直接合并的阈值：同一人的两段 embedding 余弦通常 >= 0.78。
    /// 只有相似度显著高于此值的窗口对才在第一轮直接归为同一 global speaker。
    public static let embeddingMergeThreshold = 0.78
    public static let minimumEmbeddingConfidence = 0.65
    /// 第二轮层次合并的"绝对下限"。一对说话人余弦低于此值一定是不同人，
    /// 无论算法怎么想收敛都不会强行合。
    public static let collapseAbsoluteThreshold = 0.55
    /// gap 判定：把候选合并按相似度降序排队，当下一次合并的相似度
    /// 相对上一次合并"跌落 gap ≥ 该值"时，说明触到了自然的说话人边界，停止合并。
    public static let collapseGapThreshold = 0.10

    public static func localSpeakerKey(windowIndex: Int, speakerKey: String) -> String {
        "\(windowIndex):\(speakerKey)"
    }

    public static func stitch(
        windowedTurns: [WindowedDiarizationTurn],
        embeddingsByLocalSpeakerKey: [String: VoiceprintResult],
        embeddingMergeThreshold: Double = embeddingMergeThreshold,
        minimumEmbeddingConfidence: Double = minimumEmbeddingConfidence
    ) -> [DiarizationTurn] {
        let sorted = windowedTurns
            .filter { $0.turn.endMs > $0.turn.startMs }
            .sorted { left, right in
                if left.turn.startMs == right.turn.startMs {
                    return left.turn.endMs < right.turn.endMs
                }
                return left.turn.startMs < right.turn.startMs
            }
        var globalKeysByLocalKey: [String: String] = [:]
        var representativeEmbeddingByGlobalKey: [String: VoiceprintResult] = [:]
        var windowIndicesByGlobalKey: [String: Set<Int>] = [:]
        var nextGlobalIndex = 1
        var stitched: [DiarizationTurn] = []

        for item in sorted {
            let localKey = localSpeakerKey(windowIndex: item.window.index, speakerKey: item.turn.speakerKey)
            let globalKey: String
            if let existing = globalKeysByLocalKey[localKey] {
                globalKey = existing
            } else if let matched = matchGlobalKey(
                localKey: localKey,
                windowIndex: item.window.index,
                embeddingsByLocalSpeakerKey: embeddingsByLocalSpeakerKey,
                representativeEmbeddingByGlobalKey: representativeEmbeddingByGlobalKey,
                windowIndicesByGlobalKey: windowIndicesByGlobalKey,
                threshold: embeddingMergeThreshold,
                minimumConfidence: minimumEmbeddingConfidence
            ) {
                globalKey = matched
                globalKeysByLocalKey[localKey] = matched
            } else {
                globalKey = String(format: "SPEAKER_GLOBAL_%02d", nextGlobalIndex)
                nextGlobalIndex += 1
                globalKeysByLocalKey[localKey] = globalKey
            }

            if representativeEmbeddingByGlobalKey[globalKey] == nil,
               let embedding = embeddingsByLocalSpeakerKey[localKey],
               embedding.confidence >= minimumEmbeddingConfidence,
               !embedding.embedding.isEmpty {
                representativeEmbeddingByGlobalKey[globalKey] = embedding
            }
            windowIndicesByGlobalKey[globalKey, default: []].insert(item.window.index)

            stitched.append(
                DiarizationTurn(
                    startMs: item.turn.startMs,
                    endMs: item.turn.endMs,
                    speakerKey: globalKey,
                    confidence: item.turn.confidence
                )
            )
        }

        // 数据驱动的二次收敛：完全不使用"目标人数"或"软上限"这类外部输入，
        // 由 embedding 之间的自然相似度间隙（gap）决定何时停止合并。
        //
        // 同时保留一个硬约束：CAM++ 在同一 window 里明确切开的两个 speaker
        // 一定不合并。CAM++ 的时间分离信息（"这两段的说话人不同"）比拼接侧的
        // embedding 相似度更可靠。
        let merged = mergeAdjacentTurns(stitched)
        return autoCollapseByGap(
            turns: merged,
            representativeEmbeddingByGlobalKey: representativeEmbeddingByGlobalKey,
            windowIndicesByGlobalKey: windowIndicesByGlobalKey,
            absoluteThreshold: collapseAbsoluteThreshold,
            gapThreshold: collapseGapThreshold
        )
    }

    /// 层次聚合停止条件：
    /// - 一对 speaker 相似度低于 `absoluteThreshold` 一律视作不同人，不再合并。
    /// - 若一次拟合并的相似度 `s_cur` 比上一次真实执行过的合并的相似度 `s_prev`
    ///   跌落 ≥ `gapThreshold`，认为已经跨过说话人自然边界，停止。
    /// - 只要满足以上两条，就一直吃掉相似度最高的一对——这样"5 段真正同人"的
    ///   连续高相似度合并不会被半路截断。
    private static func autoCollapseByGap(
        turns: [DiarizationTurn],
        representativeEmbeddingByGlobalKey: [String: VoiceprintResult],
        windowIndicesByGlobalKey: [String: Set<Int>],
        absoluteThreshold: Double,
        gapThreshold: Double
    ) -> [DiarizationTurn] {
        var currentTurns = turns
        var reps = representativeEmbeddingByGlobalKey
        var windowIndices = windowIndicesByGlobalKey
        // sampleCounts 用于 embedding 平均时按已合并样本数加权，比无脑均值更稳。
        var sampleCounts: [String: Int] = Dictionary(uniqueKeysWithValues: reps.keys.map { ($0, 1) })
        var lastMergedSimilarity: Double? = nil

        while true {
            let liveKeys = Set(currentTurns.map(\.speakerKey)).sorted()
            guard liveKeys.count > 1 else { break }
            var bestPair: (target: String, victim: String, score: Double)? = nil
            for i in 0..<liveKeys.count {
                for j in (i + 1)..<liveKeys.count {
                    let a = liveKeys[i]
                    let b = liveKeys[j]
                    guard let ea = reps[a]?.embedding, let eb = reps[b]?.embedding,
                          !ea.isEmpty, !eb.isEmpty else { continue }
                    // 硬约束：如果两个 global 曾在同一 window 内同时出现，
                    // 说明 CAM++ 认为它们是不同说话人，即便 embedding 相似度极高也不合并。
                    let sharedWindow = !((windowIndices[a] ?? []).isDisjoint(with: windowIndices[b] ?? []))
                    if sharedWindow { continue }
                    let score = cosineSimilarity(ea, eb)
                    if bestPair == nil || score > bestPair!.score {
                        bestPair = (a, b, score)
                    }
                }
            }
            guard let best = bestPair else { break }
            // 绝对下限：低于此值一定是不同人
            if best.score < absoluteThreshold { break }
            // gap：这次相似度比上次真实合并的相似度低太多，说明已经跨过说话人边界
            if let prev = lastMergedSimilarity, prev - best.score >= gapThreshold {
                break
            }
            // 执行合并
            let target = best.target
            let victim = best.victim
            currentTurns = currentTurns.map { turn -> DiarizationTurn in
                guard turn.speakerKey == victim else { return turn }
                return DiarizationTurn(
                    startMs: turn.startMs,
                    endMs: turn.endMs,
                    speakerKey: target,
                    confidence: turn.confidence
                )
            }
            // 加权均值：把 embedding 的样本贡献考虑进去
            let nTarget = sampleCounts[target, default: 1]
            let nVictim = sampleCounts[victim, default: 1]
            if let ea = reps[target]?.embedding, let eb = reps[victim]?.embedding, ea.count == eb.count {
                let total = Double(nTarget + nVictim)
                let mergedEmbedding = zip(ea, eb).map { pair -> Double in
                    (pair.0 * Double(nTarget) + pair.1 * Double(nVictim)) / total
                }
                let mergedConfidence = max(reps[target]?.confidence ?? 0, reps[victim]?.confidence ?? 0)
                reps[target] = VoiceprintResult(embedding: mergedEmbedding, confidence: mergedConfidence)
            }
            windowIndices[target] = (windowIndices[target] ?? []).union(windowIndices[victim] ?? [])
            windowIndices.removeValue(forKey: victim)
            sampleCounts[target] = nTarget + nVictim
            reps.removeValue(forKey: victim)
            sampleCounts.removeValue(forKey: victim)
            lastMergedSimilarity = best.score
        }
        return mergeAdjacentTurns(currentTurns)
    }

    private static func matchGlobalKey(
        localKey: String,
        windowIndex: Int,
        embeddingsByLocalSpeakerKey: [String: VoiceprintResult],
        representativeEmbeddingByGlobalKey: [String: VoiceprintResult],
        windowIndicesByGlobalKey: [String: Set<Int>],
        threshold: Double,
        minimumConfidence: Double
    ) -> String? {
        guard let localEmbedding = embeddingsByLocalSpeakerKey[localKey],
              localEmbedding.confidence >= minimumConfidence,
              !localEmbedding.embedding.isEmpty else {
            return nil
        }

        return representativeEmbeddingByGlobalKey
            .compactMap { globalKey, representative -> (String, Double)? in
                guard !(windowIndicesByGlobalKey[globalKey] ?? []).contains(windowIndex) else {
                    return nil
                }
                guard representative.confidence >= minimumConfidence else {
                    return nil
                }
                let score = cosineSimilarity(localEmbedding.embedding, representative.embedding)
                guard score >= threshold else {
                    return nil
                }
                return (globalKey, score)
            }
            .max { left, right in left.1 < right.1 }?
            .0
    }

    private static func mergeAdjacentTurns(_ turns: [DiarizationTurn]) -> [DiarizationTurn] {
        var merged: [DiarizationTurn] = []
        for turn in turns.sorted(by: { left, right in
            if left.startMs == right.startMs {
                return left.endMs < right.endMs
            }
            return left.startMs < right.startMs
        }) {
            guard var last = merged.popLast() else {
                merged.append(turn)
                continue
            }
            if last.speakerKey == turn.speakerKey, turn.startMs <= last.endMs {
                last.endMs = max(last.endMs, turn.endMs)
                last.confidence = max(last.confidence, turn.confidence)
                merged.append(last)
            } else {
                merged.append(last)
                merged.append(turn)
            }
        }
        return merged
    }
}
