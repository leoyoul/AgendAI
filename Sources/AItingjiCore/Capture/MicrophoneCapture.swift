import AVFoundation
import Foundation

public final class MicrophoneCapture: NSObject, AudioCaptureSession, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let source: CaptureSource = .microphone

    private let permissionService: PermissionService
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let outputQueue = DispatchQueue(label: "ai-tingji.microphone-output")
    private let stateLock = NSLock()
    private var callbacks: AudioCaptureCallbacks?
    private var running = false
    private var sequence = 0
    private var startTime = Date()
    private var chunkAccumulator = AudioChunkAccumulator(targetDurationMs: 1000)
    private let deviceID: String?
    /// 外部注入的共享时基。MixedAudioCapture 用这个把 mic/screen 对齐到同一 clock。
    private let sharedStartTimeProvider: (() -> Date)?

    public init(
        deviceID: String? = nil,
        permissionService: PermissionService = PermissionService()
    ) {
        self.deviceID = deviceID
        self.permissionService = permissionService
        self.sharedStartTimeProvider = nil
    }

    /// 允许调用方注入共享 startTime。这个 provider 会在 start() 内被调用一次。
    public init(
        deviceID: String? = nil,
        permissionService: PermissionService = PermissionService(),
        sharedStartTimeProvider: @escaping () -> Date
    ) {
        self.deviceID = deviceID
        self.permissionService = permissionService
        self.sharedStartTimeProvider = sharedStartTimeProvider
    }

    public var isRunning: Bool {
        stateLock.withLock { running }
    }

    public func start(callbacks: AudioCaptureCallbacks) async throws {
        if permissionService.microphoneStatus() == .notDetermined {
            let granted = await permissionService.requestMicrophoneAccess()
            guard granted else {
                throw AudioCaptureError.permissionDenied("麦克风权限未授权")
            }
        }

        guard permissionService.microphoneStatus() == .authorized else {
            throw AudioCaptureError.permissionDenied("麦克风权限未授权")
        }

        startTime = sharedStartTimeProvider?() ?? Date()
        stateLock.withLock {
            sequence = 0
        }
        outputQueue.sync {
            chunkAccumulator.reset()
        }
        self.callbacks = callbacks

        do {
            try configureSession()
            output.setSampleBufferDelegate(self, queue: outputQueue)
            session.startRunning()
            setRunning(true)
        } catch {
            output.setSampleBufferDelegate(nil, queue: nil)
            outputQueue.sync {
                chunkAccumulator.reset()
            }
            self.callbacks = nil
            throw AudioCaptureError.startFailed(error.localizedDescription)
        }
    }

    public func stop() async {
        session.stopRunning()
        output.setSampleBufferDelegate(nil, queue: nil)

        let pendingChunks = outputQueue.sync { drainAccumulatedChunks() }
        for chunk in pendingChunks {
            callbacks?.onChunk(chunk)
        }

        callbacks = nil
        setRunning(false)
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
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

    private func configureSession() throws {
        if session.isRunning {
            return
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        let device: AVCaptureDevice
        if let deviceID {
            guard let selectedDevice = MicrophoneDeviceCatalog.captureDevice(id: deviceID) else {
                throw AudioCaptureError.unsupported("选择的麦克风已断开，请刷新设备后重新选择")
            }
            device = selectedDevice
        } else {
            guard let defaultDevice = AVCaptureDevice.default(for: .audio) else {
                throw AudioCaptureError.unsupported("没有可用麦克风输入设备")
            }
            device = defaultDevice
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw AudioCaptureError.startFailed("无法添加麦克风输入设备")
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            throw AudioCaptureError.startFailed("无法添加麦克风输出")
        }
        session.addOutput(output)
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

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
