import Foundation

public struct TranscriptAudioCoverageDecision: Equatable, Sendable {
    public var isAccepted: Bool
    public var reason: String?
    public var timelineOffsetMs: Int

    public static let accepted = TranscriptAudioCoverageDecision(isAccepted: true, reason: nil, timelineOffsetMs: 0)

    public static func accepted(timelineOffsetMs: Int) -> TranscriptAudioCoverageDecision {
        TranscriptAudioCoverageDecision(isAccepted: true, reason: nil, timelineOffsetMs: timelineOffsetMs)
    }

    public static func rejected(_ reason: String) -> TranscriptAudioCoverageDecision {
        TranscriptAudioCoverageDecision(isAccepted: false, reason: reason, timelineOffsetMs: 0)
    }
}

public enum TranscriptAudioCoverage {
    private static let allowedTrailingGapMs = 5_000
    private static let minimumOffsetCandidateMs = 1_000

    public static func validate(
        audioDurationMs: Int,
        segments: [TranscriptSegment]
    ) -> TranscriptAudioCoverageDecision {
        let maxSegmentEndMs = segments.map(\.endMs).max() ?? 0
        guard maxSegmentEndMs > 0 else {
            return .accepted
        }
        if let offsetMs = inferredTimelineOffsetMs(audioDurationMs: audioDurationMs, segments: segments) {
            return .accepted(timelineOffsetMs: offsetMs)
        }
        guard audioDurationMs + allowedTrailingGapMs >= maxSegmentEndMs else {
            return .rejected(
                "录音时长 \(secondsText(audioDurationMs)) 秒，短于当前转写时间轴 \(secondsText(maxSegmentEndMs)) 秒，已保留原记录。"
            )
        }
        return .accepted
    }

    private static func inferredTimelineOffsetMs(audioDurationMs: Int, segments: [TranscriptSegment]) -> Int? {
        let sortedSegments = segments.sorted { $0.startMs < $1.startMs }
        let maxSegmentEndMs = sortedSegments.map(\.endMs).max() ?? 0
        guard audioDurationMs + allowedTrailingGapMs < maxSegmentEndMs else {
            return nil
        }

        let candidates = sortedSegments
            .map(\.endMs)
            .filter { $0 >= minimumOffsetCandidateMs }
            .filter { $0 <= maxSegmentEndMs - audioDurationMs + allowedTrailingGapMs }
            .sorted()

        return candidates.first { offsetMs in
            let shiftedSegments = sortedSegments.filter { $0.startMs >= offsetMs }
            guard !shiftedSegments.isEmpty else {
                return false
            }
            let shiftedMaxEndMs = (shiftedSegments.map(\.endMs).max() ?? 0) - offsetMs
            return shiftedMaxEndMs <= audioDurationMs + allowedTrailingGapMs
        }
    }

    private static func secondsText(_ milliseconds: Int) -> String {
        String(format: "%.1f", Double(milliseconds) / 1_000)
    }
}
