import Foundation

public enum RecordingTimelineContinuation {
    public static func nextOffsetMs(existingSegments: [TranscriptSegment]) -> Int {
        existingSegments.map(\.endMs).max() ?? 0
    }

    public static func apply(offsetMs: Int, to segment: ASRSegment) -> ASRSegment {
        let safeOffset = max(0, offsetMs)
        return ASRSegment(
            startMs: max(0, segment.startMs + safeOffset),
            endMs: max(0, segment.endMs + safeOffset),
            text: segment.text
        )
    }
}
