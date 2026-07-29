public enum MeetingSidebarActivityPresentation: Equatable, Sendable {
    case recording
    case postprocessing
    case recentlyCompleted
    case none

    public init(
        isRecording: Bool,
        isPostprocessing: Bool,
        isRecentlyCompleted: Bool
    ) {
        if isRecording {
            self = .recording
        } else if isPostprocessing {
            self = .postprocessing
        } else if isRecentlyCompleted {
            self = .recentlyCompleted
        } else {
            self = .none
        }
    }
}
