import Foundation

public enum ScreenRecordingPermissionRequestDecision: Equatable, Sendable {
    case alreadyAuthorized(String)
    case requestSystemPrompt
}

public enum ScreenRecordingPermissionRequestPolicy {
    public static func evaluate(status: CapturePermissionStatus) -> ScreenRecordingPermissionRequestDecision {
        switch status {
        case .authorized:
            return .alreadyAuthorized("屏幕录制已授权，不需要再次授权。")
        case .denied, .notDetermined, .unknown:
            return .requestSystemPrompt
        }
    }
}
