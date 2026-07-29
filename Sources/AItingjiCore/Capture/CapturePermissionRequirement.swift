import Foundation

public enum CapturePermissionKind: Equatable, Sendable {
    case microphone
    case screenRecording
}

public struct CapturePermissionRequirement: Equatable, Sendable {
    public var requiresMicrophone: Bool
    public var requiresScreenRecording: Bool

    public init(source: CaptureSource) {
        switch source {
        case .microphone:
            requiresMicrophone = true
            requiresScreenRecording = false
        case .screenAudio, .appAudio, .systemAudio:
            requiresMicrophone = false
            requiresScreenRecording = true
        case .mixed:
            requiresMicrophone = true
            requiresScreenRecording = true
        case .imported:
            requiresMicrophone = false
            requiresScreenRecording = false
        }
    }
}

public struct CapturePermissionSnapshot: Equatable, Sendable {
    public var microphone: CapturePermissionStatus
    public var screenRecording: CapturePermissionStatus

    public init(
        microphone: CapturePermissionStatus = .unknown,
        screenRecording: CapturePermissionStatus = .unknown
    ) {
        self.microphone = microphone
        self.screenRecording = screenRecording
    }
}

public struct CapturePermissionGuidance: Equatable, Sendable {
    public var requirement: CapturePermissionRequirement
    public var microphone: CapturePermissionStatus
    public var screenRecording: CapturePermissionStatus

    public init(
        requirement: CapturePermissionRequirement,
        microphone: CapturePermissionStatus,
        screenRecording: CapturePermissionStatus
    ) {
        self.requirement = requirement
        self.microphone = microphone
        self.screenRecording = screenRecording
    }

    public var missingPermissions: [CapturePermissionKind] {
        var missing: [CapturePermissionKind] = []
        if requirement.requiresMicrophone, microphone != .authorized {
            missing.append(.microphone)
        }
        if requirement.requiresScreenRecording, screenRecording != .authorized {
            missing.append(.screenRecording)
        }
        return missing
    }

    public var canStartCapture: Bool {
        missingPermissions.isEmpty
    }

    public var summary: String {
        let missing = missingPermissions
        if missing.isEmpty {
            return "录音权限已就绪。"
        }
        if missing == [.microphone] {
            return "请先授权麦克风。"
        }
        if missing == [.screenRecording] {
            return "请先授权屏幕录制。"
        }
        return "请先授权麦克风和屏幕录制。"
    }

    public var actions: [String] {
        var result: [String] = []
        if missingPermissions.contains(.microphone) {
            result.append("打开系统设置 -> 隐私与安全性 -> 麦克风，允许会小纪使用麦克风。")
        }
        if missingPermissions.contains(.screenRecording) {
            result.append("打开系统设置 -> 隐私与安全性 -> 屏幕录制，允许会小纪采集电脑音频。")
            result.append("授权后请退出并重新打开会小纪。")
        }
        return result
    }
}
