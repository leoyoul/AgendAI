import AVFoundation
import CoreGraphics
import Foundation

public enum CapturePermissionStatus: String, Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
    case unknown
}

public struct PermissionService: Sendable {
    public init() {}

    public func microphoneStatus() -> CapturePermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unknown
        }
    }

    public func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func screenRecordingStatus() -> CapturePermissionStatus {
        CGPreflightScreenCaptureAccess() ? .authorized : .denied
    }

    @discardableResult
    public func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public func settingsURL(for permission: CapturePermissionKind) -> URL {
        switch permission {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }

    public var fallbackSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security")!
    }
}
