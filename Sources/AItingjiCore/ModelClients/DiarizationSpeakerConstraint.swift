import Foundation

public struct DiarizationSpeakerConstraint: Equatable, Sendable {
    public var minSpeakers: Int?
    public var maxSpeakers: Int?
    public var numSpeakers: Int?

    public init(minSpeakers: Int? = nil, maxSpeakers: Int? = nil, numSpeakers: Int? = nil) {
        self.minSpeakers = minSpeakers
        self.maxSpeakers = maxSpeakers
        self.numSpeakers = numSpeakers
    }

    public static var automatic: DiarizationSpeakerConstraint {
        // 不做人数硬约束：宽范围让 sidecar/CAM++ 自然分离，
        // 由拼接侧的"数据驱动层次合并"负责收敛 ECAPA 短片段震荡带来的过分。
        DiarizationSpeakerConstraint(minSpeakers: 1, maxSpeakers: 12)
    }

    public static var defaultMeeting: DiarizationSpeakerConstraint {
        .automatic
    }
}

public enum DiarizationSpeakerPreset: String, CaseIterable, Codable, Sendable {
    case automatic
    case one
    case two
    case three
    case four
    case five
    case six
    case eight

    public var displayName: String {
        switch self {
        case .automatic:
            return "自动识别发言人数"
        case .one:
            return "1 人"
        case .two:
            return "2 人"
        case .three:
            return "3 人"
        case .four:
            return "4 人"
        case .five:
            return "5 人"
        case .six:
            return "6 人"
        case .eight:
            return "8 人"
        }
    }

    public var constraint: DiarizationSpeakerConstraint {
        switch self {
        case .automatic:
            return .automatic
        case .one:
            return DiarizationSpeakerConstraint(numSpeakers: 1)
        case .two:
            // 用户选"2 人"→ 硬约束，sidecar 传 preset_spk_num=2，
            // stitcher 也把 expectedSpeakerCount=2 用作二次收敛目标。
            return DiarizationSpeakerConstraint(numSpeakers: 2)
        case .three:
            return DiarizationSpeakerConstraint(numSpeakers: 3)
        case .four:
            return DiarizationSpeakerConstraint(numSpeakers: 4)
        case .five:
            return DiarizationSpeakerConstraint(numSpeakers: 5)
        case .six:
            return DiarizationSpeakerConstraint(numSpeakers: 6)
        case .eight:
            return DiarizationSpeakerConstraint(numSpeakers: 8)
        }
    }

    public static func parse(_ value: String?) -> DiarizationSpeakerPreset {
        guard let value,
              let preset = DiarizationSpeakerPreset(rawValue: value) else {
            return .automatic
        }
        return preset
    }
}
