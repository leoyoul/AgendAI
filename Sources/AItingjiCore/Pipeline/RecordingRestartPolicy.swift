import Foundation

public struct RecordingRestartDecision: Equatable, Sendable {
    public var isAccepted: Bool
    public var reason: String?

    public static let accepted = RecordingRestartDecision(isAccepted: true, reason: nil)

    public static func rejected(_ reason: String) -> RecordingRestartDecision {
        RecordingRestartDecision(isAccepted: false, reason: reason)
    }
}

public enum RecordingRestartPolicy {
    public static func validate(
        meeting: Meeting,
        existingSegmentCount: Int
    ) -> RecordingRestartDecision {
        guard existingSegmentCount > 0, meeting.audioFilePath != nil else {
            return .accepted
        }
        return .rejected(
            "当前会议已有 \(existingSegmentCount) 条转写记录。请新建会议后再录音，避免新录音覆盖旧音频导致说话人校正错位。"
        )
    }
}
