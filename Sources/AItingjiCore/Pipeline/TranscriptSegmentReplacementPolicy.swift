import Foundation

public struct TranscriptSegmentReplacementDecision: Equatable, Sendable {
    public var isAccepted: Bool
    public var reason: String?

    public init(isAccepted: Bool, reason: String? = nil) {
        self.isAccepted = isAccepted
        self.reason = reason
    }
}

public enum TranscriptSegmentReplacementPolicy {
    public static let minimumTextRetainedRatio = 0.75
    public static let minimumTimelineCoverageRatio = 0.8

    public static func validate(
        replacementSegments: [TranscriptSegment],
        originalSegments: [TranscriptSegment]
    ) -> TranscriptSegmentReplacementDecision {
        guard !replacementSegments.isEmpty else {
            return TranscriptSegmentReplacementDecision(isAccepted: false, reason: "新片段为空，已保留原记录。")
        }
        guard !originalSegments.isEmpty else {
            return TranscriptSegmentReplacementDecision(isAccepted: true)
        }

        let originalTextCount = meaningfulCharacterCount(originalSegments)
        let replacementTextCount = meaningfulCharacterCount(replacementSegments)
        if originalTextCount > 0 {
            let retainedRatio = Double(replacementTextCount) / Double(originalTextCount)
            if retainedRatio < minimumTextRetainedRatio {
                return TranscriptSegmentReplacementDecision(
                    isAccepted: false,
                    reason: "文本保留不足，已保留原记录。"
                )
            }
        }

        let originalDuration = coveredDurationMs(originalSegments)
        let replacementDuration = coveredDurationMs(replacementSegments)
        if originalDuration > 0 {
            let coverageRatio = Double(replacementDuration) / Double(originalDuration)
            if coverageRatio < minimumTimelineCoverageRatio {
                return TranscriptSegmentReplacementDecision(
                    isAccepted: false,
                    reason: "时间覆盖不足，已保留原记录。"
                )
            }
        }

        return TranscriptSegmentReplacementDecision(isAccepted: true)
    }

    private static func meaningfulCharacterCount(_ segments: [TranscriptSegment]) -> Int {
        segments.reduce(0) { total, segment in
            total + meaningfulCharacterCount(displayText(for: segment))
        }
    }

    private static func displayText(for segment: TranscriptSegment) -> String {
        let finalText = segment.finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalText.isEmpty {
            return finalText
        }
        return segment.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func meaningfulCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || (scalar.value >= 0x4E00 && scalar.value <= 0x9FFF)
        }.count
    }

    private static func coveredDurationMs(_ segments: [TranscriptSegment]) -> Int {
        let intervals = segments
            .map { (start: min($0.startMs, $0.endMs), end: max($0.startMs, $0.endMs)) }
            .filter { $0.end > $0.start }
            .sorted { left, right in
                if left.start == right.start {
                    return left.end < right.end
                }
                return left.start < right.start
            }
        var total = 0
        var current: (start: Int, end: Int)?
        for interval in intervals {
            guard var active = current else {
                current = interval
                continue
            }
            if interval.start <= active.end {
                active.end = max(active.end, interval.end)
                current = active
            } else {
                total += active.end - active.start
                current = interval
            }
        }
        if let current {
            total += current.end - current.start
        }
        return total
    }
}
