import Foundation

public enum RecordingStartupState: Equatable, Sendable {
    case idle
    case starting
    case recording
    case paused
    case failed
}

public struct RecordingControlPresentation: Equatable, Sendable {
    public var state: RecordingStartupState

    public init(state: RecordingStartupState) {
        self.state = state
    }

    public var primaryActionTitle: String {
        state == .paused ? "继续" : "开始"
    }

    public var primaryActionSystemImage: String {
        state == .paused ? "play.circle" : "record.circle"
    }

    public var canStartOrResume: Bool {
        state == .idle || state == .failed || state == .paused
    }

    public var canPause: Bool {
        state == .recording
    }

    public var canStop: Bool {
        state == .recording || state == .paused
    }

    public var statusText: String {
        switch state {
        case .idle:
            return "未开始"
        case .starting:
            return "启动中"
        case .recording:
            return "录音中"
        case .paused:
            return "已暂停"
        case .failed:
            return "启动失败"
        }
    }

    public static func formattedElapsedTime(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds) / 1_000
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
