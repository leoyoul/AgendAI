import Foundation

public final class MixedAudioCapture: AudioCaptureSession, @unchecked Sendable {
    public let source: CaptureSource = .mixed

    private let microphone: AudioCaptureSession
    private let computerAudio: AudioCaptureSession
    private let stateLock = NSLock()
    private var running = false
    private var nextSequenceValue = 0
    private var microphonePending: [AudioChunk] = []
    private var computerPending: [AudioChunk] = []
    private var callbacks: AudioCaptureCallbacks?
    private let outputFormat = AudioFormatDescription(sampleRate: 16_000, channels: 1)

    /// 每条轨道最多保留约 8 秒待配对音频。达到上限时会按时间写出最早的单轨 chunk，
    /// 而非覆盖或丢弃它；这同时限制了单轨异常时的内存增长。
    private let maximumPendingChunksPerTrack = 8
    /// 两路采集共享时基后允许的启动抖动。正常 1 秒窗口会落在该范围内。
    private let pairingStartToleranceMs = 500

    /// 每次 start() 前重置的共享时基：两路 capture 通过其 sharedStartTimeProvider
    /// 拿到同一 startTime，保证 chunk.startMs 落在同一 clock 下。
    private let sharedClock: SharedStartClock

    public init(
        microphoneDeviceID: String? = nil,
        microphone: AudioCaptureSession? = nil,
        computerAudio: AudioCaptureSession? = nil
    ) {
        let clock = SharedStartClock()
        self.sharedClock = clock
        self.microphone = microphone ?? MicrophoneCapture(
            deviceID: microphoneDeviceID,
            sharedStartTimeProvider: clock.provider()
        )
        self.computerAudio = computerAudio ?? ScreenAudioCapture(sharedStartTimeProvider: clock.provider())
    }

    fileprivate final class SharedStartClock: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: Date?

        func reset() {
            lock.lock()
            pending = nil
            lock.unlock()
        }

        func provider() -> () -> Date {
            return { [weak self] in
                guard let self else { return Date() }
                self.lock.lock()
                defer { self.lock.unlock() }
                if let existing = self.pending {
                    return existing
                }
                let now = Date()
                self.pending = now
                return now
            }
        }
    }

    public var isRunning: Bool {
        stateLock.withLock { running }
    }

    public func start(callbacks: AudioCaptureCallbacks) async throws {
        setRunning(false)
        resetSequenceState()
        sharedClock.reset()
        self.callbacks = callbacks
        let microphoneCallbacks = AudioCaptureCallbacks(
            onChunk: { [weak self] chunk in
                guard let self else {
                    return
                }
                callbacks.onTrackChunk(.microphone, chunk)
                for mixed in self.enqueue(chunk, on: .microphone) {
                    callbacks.onChunk(mixed)
                }
            },
            onLevel: callbacks.onLevel,
            onError: callbacks.onError
        )
        let computerCallbacks = AudioCaptureCallbacks(
            onChunk: { [weak self] chunk in
                guard let self else {
                    return
                }
                callbacks.onTrackChunk(.computer, chunk)
                for mixed in self.enqueue(chunk, on: .computer) {
                    callbacks.onChunk(mixed)
                }
            },
            onLevel: callbacks.onLevel,
            onError: callbacks.onError
        )

        do {
            try await microphone.start(callbacks: microphoneCallbacks)
            try await computerAudio.start(callbacks: computerCallbacks)
            setRunning(true)
        } catch {
            await microphone.stop()
            await computerAudio.stop()
            setRunning(false)
            self.callbacks = nil
            throw error
        }
    }

    public func stop() async {
        await microphone.stop()
        await computerAudio.stop()
        for chunk in flushPendingChunks() {
            callbacks?.onChunk(chunk)
        }
        callbacks = nil
        setRunning(false)
    }

    /// 将各轨输入放入独立 FIFO。绝不按时间窗口字典覆盖同轨尚未处理的 chunk。
    private func enqueue(_ chunk: AudioChunk, on track: AudioCaptureTrack) -> [AudioChunk] {
        let normalized = normalize(chunk)
        return stateLock.withLock {
            switch track {
            case .microphone:
                microphonePending.append(normalized)
            case .computer:
                computerPending.append(normalized)
            case .mixed:
                return []
            }

            var emitted = drainPairableChunksLocked()
            emitted.append(contentsOf: flushOverflowLocked())
            return emitted.map(assignSequence)
        }
    }

    private func drainPairableChunksLocked() -> [AudioChunk] {
        var emitted: [AudioChunk] = []
        while let microphone = microphonePending.first, let computer = computerPending.first {
            if shouldPair(microphone, computer) {
                microphonePending.removeFirst()
                computerPending.removeFirst()
                emitted.append(mix(microphone, computer, windowStartMs: mixedWindowStart(microphone, computer)))
            } else if microphone.startMs < computer.startMs {
                emitted.append(microphonePending.removeFirst())
            } else if computer.startMs < microphone.startMs {
                emitted.append(computerPending.removeFirst())
            } else if microphone.sequence <= computer.sequence {
                // 时间戳完全相同但不应配对时，保持确定性并继续前进。
                emitted.append(microphonePending.removeFirst())
            } else {
                emitted.append(computerPending.removeFirst())
            }
        }
        return emitted
    }

    private func flushOverflowLocked() -> [AudioChunk] {
        var emitted: [AudioChunk] = []
        while microphonePending.count > maximumPendingChunksPerTrack {
            emitted.append(microphonePending.removeFirst())
        }
        while computerPending.count > maximumPendingChunksPerTrack {
            emitted.append(computerPending.removeFirst())
        }
        return emitted
    }

    private func shouldPair(_ microphone: AudioChunk, _ computer: AudioChunk) -> Bool {
        abs(microphone.startMs - computer.startMs) <= pairingStartToleranceMs
    }

    private func mixedWindowStart(_ microphone: AudioChunk, _ computer: AudioChunk) -> Int {
        let earliestStartMs = min(microphone.startMs, computer.startMs)
        return (earliestStartMs + 500) / 1_000 * 1_000
    }

    private func mix(_ microphone: AudioChunk, _ computer: AudioChunk, windowStartMs: Int) -> AudioChunk {
        let sampleCount = max(microphone.samples.count, computer.samples.count)
        let samples = (0..<sampleCount).map { index in
            let microphoneSample = index < microphone.samples.count ? microphone.samples[index] : 0
            let computerSample = index < computer.samples.count ? computer.samples[index] : 0
            return max(-1, min(1, microphoneSample * 0.5 + computerSample * 0.5))
        }
        let durationMs = Int(Double(samples.count) / outputFormat.sampleRate * 1000)
        return AudioChunk(
            sequence: 0,
            startMs: windowStartMs,
            endMs: windowStartMs + durationMs,
            samples: samples,
            format: outputFormat
        )
    }

    private func flushPendingChunks() -> [AudioChunk] {
        stateLock.withLock {
            let chunks = (microphonePending + computerPending).sorted { left, right in
                if left.startMs != right.startMs {
                    return left.startMs < right.startMs
                }
                return left.sequence < right.sequence
            }
            microphonePending.removeAll(keepingCapacity: true)
            computerPending.removeAll(keepingCapacity: true)
            return chunks.map(assignSequence)
        }
    }

    private func normalize(_ chunk: AudioChunk) -> AudioChunk {
        let monoSamples = downmixToMono(samples: chunk.samples, channels: chunk.format.channels)
        let samples = resample(
            monoSamples,
            fromSampleRate: chunk.format.sampleRate,
            toSampleRate: outputFormat.sampleRate
        )
        let durationMs = Int(Double(samples.count) / outputFormat.sampleRate * 1000)
        return AudioChunk(
            sequence: chunk.sequence,
            startMs: chunk.startMs,
            endMs: chunk.startMs + durationMs,
            samples: samples,
            format: outputFormat
        )
    }

    private func downmixToMono(samples: [Float], channels: Int) -> [Float] {
        let channelCount = max(1, channels)
        guard channelCount > 1 else {
            return samples
        }
        let frameCount = samples.count / channelCount
        guard frameCount > 0 else {
            return []
        }
        return (0..<frameCount).map { frame in
            let offset = frame * channelCount
            let sum = samples[offset..<(offset + channelCount)].reduce(Float(0), +)
            return sum / Float(channelCount)
        }
    }

    private func resample(_ samples: [Float], fromSampleRate: Double, toSampleRate: Double) -> [Float] {
        guard !samples.isEmpty else {
            return []
        }
        guard fromSampleRate > 0, toSampleRate > 0, fromSampleRate != toSampleRate else {
            return samples
        }

        let targetCount = max(1, Int((Double(samples.count) * toSampleRate / fromSampleRate).rounded()))
        guard samples.count > 1 else {
            return Array(repeating: samples[0], count: targetCount)
        }

        let sourceStep = fromSampleRate / toSampleRate
        return (0..<targetCount).map { index in
            let sourcePosition = Double(index) * sourceStep
            let lower = min(Int(sourcePosition.rounded(.down)), samples.count - 1)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            return samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
    }

    private func resetSequenceState() {
        stateLock.withLock {
            nextSequenceValue = 0
            microphonePending.removeAll(keepingCapacity: true)
            computerPending.removeAll(keepingCapacity: true)
        }
    }

    private func assignSequence(_ chunk: AudioChunk) -> AudioChunk {
        var chunk = chunk
        chunk.sequence = nextSequenceValue
        nextSequenceValue += 1
        return chunk
    }

    private func setRunning(_ value: Bool) {
        stateLock.withLock {
            running = value
        }
    }
}
