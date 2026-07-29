import CoreMedia
import Foundation
import ScreenCaptureKit

public final class ScreenAudioCapture: NSObject, AudioCaptureSession, SCStreamOutput, @unchecked Sendable {
    public let source: CaptureSource = .screenAudio

    private let permissionService: PermissionService
    private let outputQueue = DispatchQueue(label: "ai-tingji.screen-audio-output")
    private var stream: SCStream?
    private var callbacks: AudioCaptureCallbacks?
    private let stateLock = NSLock()
    private var running = false
    private var sequence = 0
    private var startTime = Date()
    private var chunkAccumulator = AudioChunkAccumulator(targetDurationMs: 1000)
    private let sharedStartTimeProvider: (() -> Date)?

    public init(permissionService: PermissionService = PermissionService()) {
        self.permissionService = permissionService
        self.sharedStartTimeProvider = nil
    }

    public init(
        permissionService: PermissionService = PermissionService(),
        sharedStartTimeProvider: @escaping () -> Date
    ) {
        self.permissionService = permissionService
        self.sharedStartTimeProvider = sharedStartTimeProvider
    }

    public var isRunning: Bool {
        stateLock.withLock { running }
    }

    public func availableTargetCount() async throws -> Int {
        let content = try await SCShareableContent.current
        return content.displays.count + content.windows.count + content.applications.count
    }

    public func start(callbacks: AudioCaptureCallbacks) async throws {
        guard permissionService.screenRecordingStatus() == .authorized else {
            throw AudioCaptureError.permissionDenied("屏幕录制权限未授权")
        }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw AudioCaptureError.unsupported("没有可采集的屏幕目标")
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        self.callbacks = callbacks
        self.stream = stream
        stateLock.withLock {
            sequence = 0
        }
        self.startTime = sharedStartTimeProvider?() ?? Date()
        outputQueue.sync {
            chunkAccumulator.reset()
        }

        do {
            try await stream.startCapture()
            setRunning(true)
        } catch {
            self.stream = nil
            self.callbacks = nil
            outputQueue.sync {
                chunkAccumulator.reset()
            }
            throw error
        }
    }

    public func stop() async {
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                callbacks?.onError(.startFailed(error.localizedDescription))
            }
        }

        let pendingChunks = outputQueue.sync { drainAccumulatedChunks() }
        for chunk in pendingChunks {
            callbacks?.onChunk(chunk)
        }

        self.stream = nil
        self.callbacks = nil
        setRunning(false)
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else {
            return
        }
        guard let extracted = AudioSampleExtractor.extractSamples(from: sampleBuffer),
              !extracted.samples.isEmpty else {
            return
        }

        callbacks?.onLevel(AudioChunker(format: extracted.format).peakLevel(samples: extracted.samples))
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)
        let durationMs = Int(
            Double(extracted.samples.count)
                / (extracted.format.sampleRate * Double(max(1, extracted.format.channels)))
                * 1000
        )
        let input = AudioChunk(
            sequence: 0,
            startMs: elapsedMs,
            endMs: elapsedMs + durationMs,
            samples: extracted.samples,
            format: extracted.format
        )
        for chunk in chunkAccumulator.appendAll(input) {
            callbacks?.onChunk(assignSequence(to: chunk))
        }
    }

    private func drainAccumulatedChunks() -> [AudioChunk] {
        chunkAccumulator.flushAll().map(assignSequence(to:))
    }

    private func assignSequence(to chunk: AudioChunk) -> AudioChunk {
        var chunk = chunk
        chunk.sequence = nextSequence()
        return chunk
    }

    private func setRunning(_ value: Bool) {
        stateLock.withLock {
            running = value
        }
    }

    private func nextSequence() -> Int {
        stateLock.withLock {
            defer { sequence += 1 }
            return sequence
        }
    }
}
