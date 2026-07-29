import Foundation

public final class MeetingAudioTrackWriters: @unchecked Sendable {
    public let mixedURL: URL
    public let microphoneURL: URL?
    public let computerURL: URL?

    private let mixedWriter: MeetingAudioWriter
    private let microphoneWriter: MeetingAudioWriter?
    private let computerWriter: MeetingAudioWriter?

    public var mixedDurationMs: Int {
        mixedWriter.durationMs
    }

    public init(mixedURL: URL, microphoneURL: URL? = nil, computerURL: URL? = nil) throws {
        self.mixedURL = mixedURL
        self.microphoneURL = microphoneURL
        self.computerURL = computerURL
        mixedWriter = try MeetingAudioWriter(url: mixedURL)
        do {
            microphoneWriter = try microphoneURL.map { try MeetingAudioWriter(url: $0) }
            computerWriter = try computerURL.map { try MeetingAudioWriter(url: $0) }
        } catch {
            try? mixedWriter.finish()
            throw error
        }
    }

    deinit {
        try? finish()
    }

    public func appendMixed(_ chunk: AudioChunk) throws {
        try mixedWriter.append(chunk)
    }

    public func appendTrack(_ track: AudioCaptureTrack, chunk: AudioChunk) throws {
        switch track {
        case .microphone:
            try microphoneWriter?.append(chunk)
        case .computer:
            try computerWriter?.append(chunk)
        case .mixed:
            try mixedWriter.append(chunk)
        }
    }

    public func finish() throws {
        var firstError: Error?
        do {
            try mixedWriter.finish()
        } catch {
            firstError = firstError ?? error
        }
        do {
            try microphoneWriter?.finish()
        } catch {
            firstError = firstError ?? error
        }
        do {
            try computerWriter?.finish()
        } catch {
            firstError = firstError ?? error
        }
        if let firstError {
            throw firstError
        }
    }

    /// 把所有已打开的写入器的 header + PCM 立即同步到磁盘，不关闭句柄。
    /// 供 pause 场景调用，保证暂停期间硬崩留下的 WAV 都可以直接播放。
    public func flush() throws {
        var firstError: Error?
        do { try mixedWriter.flush() } catch { firstError = firstError ?? error }
        do { try microphoneWriter?.flush() } catch { firstError = firstError ?? error }
        do { try computerWriter?.flush() } catch { firstError = firstError ?? error }
        if let firstError { throw firstError }
    }
}
