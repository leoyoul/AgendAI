import Foundation

public enum AudioCaptureError: Error, Equatable, Sendable {
    case permissionDenied(String)
    case unsupported(String)
    case startFailed(String)
    case stopped
}

public struct AudioFormatDescription: Equatable, Sendable {
    public var sampleRate: Double
    public var channels: Int
    public var sampleFormat: String

    public init(sampleRate: Double, channels: Int, sampleFormat: String = "pcm_f32") {
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleFormat = sampleFormat
    }
}

public struct AudioChunk: Equatable, Sendable {
    public var sequence: Int
    public var startMs: Int
    public var endMs: Int
    public var samples: [Float]
    public var format: AudioFormatDescription

    public init(
        sequence: Int,
        startMs: Int,
        endMs: Int,
        samples: [Float],
        format: AudioFormatDescription
    ) {
        self.sequence = sequence
        self.startMs = startMs
        self.endMs = endMs
        self.samples = samples
        self.format = format
    }
}

public struct AudioCaptureCallbacks: Sendable {
    public var onChunk: @Sendable (AudioChunk) -> Void
    public var onTrackChunk: @Sendable (AudioCaptureTrack, AudioChunk) -> Void
    public var onLevel: @Sendable (Float) -> Void
    public var onError: @Sendable (AudioCaptureError) -> Void

    public init(
        onChunk: @escaping @Sendable (AudioChunk) -> Void,
        onTrackChunk: @escaping @Sendable (AudioCaptureTrack, AudioChunk) -> Void = { _, _ in },
        onLevel: @escaping @Sendable (Float) -> Void = { _ in },
        onError: @escaping @Sendable (AudioCaptureError) -> Void = { _ in }
    ) {
        self.onChunk = onChunk
        self.onTrackChunk = onTrackChunk
        self.onLevel = onLevel
        self.onError = onError
    }
}

public protocol AudioCaptureSession: AnyObject, Sendable {
    var source: CaptureSource { get }
    var isRunning: Bool { get }

    func start(callbacks: AudioCaptureCallbacks) async throws
    func stop() async
}
