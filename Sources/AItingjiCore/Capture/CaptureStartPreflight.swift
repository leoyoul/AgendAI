import Foundation

public struct CaptureStartPreflightBlock: Equatable, Sendable {
    public var missingPermissions: [CapturePermissionKind]
    public var message: String
    public var canSwitchToMicrophone: Bool

    public init(
        missingPermissions: [CapturePermissionKind],
        message: String,
        canSwitchToMicrophone: Bool
    ) {
        self.missingPermissions = missingPermissions
        self.message = message
        self.canSwitchToMicrophone = canSwitchToMicrophone
    }
}

public enum CaptureStartPreflightResult: Equatable, Sendable {
    case allowed
    case blocked(CaptureStartPreflightBlock)
}

public enum CaptureStartPreflight {
    public static func evaluate(
        source: CaptureSource,
        snapshot: CapturePermissionSnapshot
    ) -> CaptureStartPreflightResult {
        let guidance = CapturePermissionGuidance(
            requirement: CapturePermissionRequirement(source: source),
            microphone: snapshot.microphone,
            screenRecording: snapshot.screenRecording
        )
        let missing = guidance.missingPermissions
        guard !missing.isEmpty else {
            return .allowed
        }

        return .blocked(
            CaptureStartPreflightBlock(
                missingPermissions: missing,
                message: RecordingStartupFailureMessage.permission(missing: missing),
                canSwitchToMicrophone: canSwitchToMicrophone(source: source, snapshot: snapshot, missing: missing)
            )
        )
    }

    private static func canSwitchToMicrophone(
        source: CaptureSource,
        snapshot: CapturePermissionSnapshot,
        missing: [CapturePermissionKind]
    ) -> Bool {
        source != .microphone
            && snapshot.microphone == .authorized
            && missing.contains(.screenRecording)
    }
}

public enum RecordingStartupFailureMessage {
    public static func permission(missing: [CapturePermissionKind]) -> String {
        let hasMicrophone = missing.contains(.microphone)
        let hasScreenRecording = missing.contains(.screenRecording)

        if hasMicrophone, hasScreenRecording {
            return "录音未开始：请先授权麦克风和屏幕录制，授权后退出并重新打开会小纪。"
        }
        if hasMicrophone {
            return "录音未开始：请先授权麦克风。"
        }
        if hasScreenRecording {
            return "录音未开始：请先授权屏幕录制，授权后退出并重新打开会小纪。"
        }
        return "录音未开始：权限检查失败。"
    }

    public static func asrWarmup(_ detail: String) -> String {
        "录音未开始：ASR 模型预热失败：\(normalizedDetail(detail))"
    }

    public static func voiceprintWarmup(_ detail: String) -> String {
        "录音未开始：声纹模型预热失败：\(normalizedDetail(detail))"
    }

    public static func captureStart(source: CaptureSource, detail: String) -> String {
        "录音未开始：\(captureSourceName(source))采集启动失败：\(normalizedDetail(detail))"
    }

    private static func captureSourceName(_ source: CaptureSource) -> String {
        switch source {
        case .microphone:
            return "麦克风"
        case .screenAudio, .appAudio, .systemAudio:
            return "电脑音频"
        case .mixed:
            return "麦克风+电脑音频"
        case .imported:
            return "外部转写"
        }
    }

    private static func normalizedDetail(_ detail: String) -> String {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未知错误" : trimmed
    }
}
