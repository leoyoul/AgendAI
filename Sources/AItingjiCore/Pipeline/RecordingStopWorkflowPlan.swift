public enum RecordingStopWorkflowStep: Equatable, Sendable {
    case drainPendingRealtimeTranscription
    case finishAudioCapture
    case polishRealtimeTranscript
    case updateMeetingTitle
    case retranscribeFullRecording
    case separateSpeakers
    case generateMeetingMinutes
}

public struct RecordingStopWorkflowPlan: Equatable, Sendable {
    public let steps: [RecordingStopWorkflowStep]

    public init(steps: [RecordingStopWorkflowStep]) {
        self.steps = steps
    }

    public static let automatic = RecordingStopWorkflowPlan(
        steps: [
            .drainPendingRealtimeTranscription,
            .finishAudioCapture,
            .generateMeetingMinutes,
            .updateMeetingTitle
        ]
    )
}
