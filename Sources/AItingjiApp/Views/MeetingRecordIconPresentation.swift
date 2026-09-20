import AItingjiCore

enum MeetingRecordIconPresentation: Equatable {
    case standard
    case recording
    case processing
    case recentlyCompleted

    init(activity: MeetingSidebarActivityPresentation) {
        switch activity {
        case .recording:
            self = .recording
        case .postprocessing:
            self = .processing
        case .recentlyCompleted:
            self = .recentlyCompleted
        case .none:
            self = .standard
        }
    }

    var systemImage: String {
        switch self {
        case .standard: "calendar"
        case .recording: "record.circle.fill"
        case .processing: "clock.arrow.circlepath"
        case .recentlyCompleted: "checkmark.circle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .standard: "会议"
        case .recording: "正在录音"
        case .processing: "会议纪要排队或生成中"
        case .recentlyCompleted: "会议纪要已生成"
        }
    }

    var isPulsing: Bool {
        self == .recording
    }
}
