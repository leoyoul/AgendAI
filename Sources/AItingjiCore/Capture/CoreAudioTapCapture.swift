import CoreAudio
import Foundation

public struct CoreAudioTapCapability: Equatable, Sendable {
    public var isAvailable: Bool
    public var minimumMacOS: String
    public var note: String

    public init(isAvailable: Bool, minimumMacOS: String = "14.2", note: String) {
        self.isAvailable = isAvailable
        self.minimumMacOS = minimumMacOS
        self.note = note
    }
}

public final class CoreAudioTapCapture: AudioCaptureSession, @unchecked Sendable {
    public let source: CaptureSource = .appAudio

    private let stateLock = NSLock()
    private var running = false

    public init() {}

    public var isRunning: Bool {
        stateLock.withLock { running }
    }

    public func capability() -> CoreAudioTapCapability {
        if #available(macOS 14.2, *) {
            return CoreAudioTapCapability(
                isAvailable: true,
                note: "当前系统 SDK 支持 Core Audio Process Tap，后续可接入指定进程音频采集。"
            )
        }
        return CoreAudioTapCapability(
            isAvailable: false,
            note: "Core Audio Process Tap 需要 macOS 14.2 或更高版本。"
        )
    }

    public func start(callbacks: AudioCaptureCallbacks) async throws {
        guard capability().isAvailable else {
            throw AudioCaptureError.unsupported(capability().note)
        }
        setRunning(true)
        callbacks.onError(.unsupported("Core Audio Tap 目前是技术验证骨架，尚未接入真实进程音频流。"))
    }

    public func stop() async {
        setRunning(false)
    }

    private func setRunning(_ value: Bool) {
        stateLock.withLock {
            running = value
        }
    }
}
