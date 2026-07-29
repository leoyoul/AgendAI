import Foundation

public enum DiarizedTurnRetranscriptionPlanner {
    public static let minimumDurationMs = 700
    public static let maximumMergedDurationMs = 12_000
    public static let maximumGapMs = 600

    public static func plan(
        turns: [DiarizationTurn],
        manualSegments: [TranscriptSegment]
    ) -> [DiarizationTurn] {
        let mergedTurns = merge(turns)
        let manualIntervals = manualSegments
            .map { (startMs: $0.startMs, endMs: $0.endMs) }
            .sorted { $0.startMs < $1.startMs }
        return mergedTurns.flatMap { subtract(manualIntervals: manualIntervals, from: $0) }
            .filter { $0.endMs - $0.startMs >= minimumDurationMs }
            .sorted { $0.startMs < $1.startMs }
    }

    private static func merge(_ turns: [DiarizationTurn]) -> [DiarizationTurn] {
        let sortedTurns = turns
            .filter { $0.endMs - $0.startMs >= minimumDurationMs }
            .sorted { $0.startMs < $1.startMs }
        var merged: [DiarizationTurn] = []
        for turn in sortedTurns {
            guard var last = merged.popLast() else {
                merged.append(turn)
                continue
            }
            let canMerge = last.speakerKey == turn.speakerKey
                && turn.startMs - last.endMs <= maximumGapMs
                && turn.endMs - last.startMs <= maximumMergedDurationMs
            if canMerge {
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

    private static func subtract(
        manualIntervals: [(startMs: Int, endMs: Int)],
        from turn: DiarizationTurn
    ) -> [DiarizationTurn] {
        var cursor = turn.startMs
        var pieces: [DiarizationTurn] = []
        for interval in manualIntervals where interval.endMs > turn.startMs && interval.startMs < turn.endMs {
            let intervalStart = max(turn.startMs, interval.startMs)
            let intervalEnd = min(turn.endMs, interval.endMs)
            if intervalStart > cursor {
                pieces.append(
                    DiarizationTurn(
                        startMs: cursor,
                        endMs: intervalStart,
                        speakerKey: turn.speakerKey,
                        confidence: turn.confidence
                    )
                )
            }
            cursor = max(cursor, intervalEnd)
        }
        if cursor < turn.endMs {
            pieces.append(
                DiarizationTurn(
                    startMs: cursor,
                    endMs: turn.endMs,
                    speakerKey: turn.speakerKey,
                    confidence: turn.confidence
                )
            )
        }
        return pieces
    }
}
