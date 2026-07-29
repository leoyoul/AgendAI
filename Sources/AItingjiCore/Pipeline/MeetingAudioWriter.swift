import Foundation

public final class MeetingAudioWriter: @unchecked Sendable {
    private let url: URL
    private let handle: FileHandle
    private let outputFormat = AudioFormatDescription(sampleRate: 16_000, channels: 1)
    private var pcmByteCount: UInt32 = 0
    private var isFinished = false

    /// 已写入的有效录音时长。暂停恢复必须以它为唯一时间轴基准，不能由转写文本反推。
    public var durationMs: Int {
        Int((UInt64(pcmByteCount) * 1_000) / 32_000)
    }

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: Self.wavHeader(pcmByteCount: 0))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit {
        try? finish()
    }

    public func append(_ chunk: AudioChunk) throws {
        guard !isFinished else {
            return
        }
        let normalized = normalize(chunk)
        let pcmData = pcm16Data(samples: normalized.samples)
        try handle.write(contentsOf: pcmData)
        pcmByteCount += UInt32(pcmData.count)
        try updateHeader()
    }

    public func finish() throws {
        guard !isFinished else {
            return
        }
        isFinished = true
        try updateHeader()
        try handle.synchronize()
        try handle.close()
    }

    /// 立即把 header 与已写入的 PCM 同步到磁盘，且**不关闭**句柄。
    /// 用于录音 pause：保证暂停期间硬崩溃留下的 WAV 头字段是最新的，可直接播放。
    /// pause 之后仍可继续 append。
    public func flush() throws {
        guard !isFinished else { return }
        try updateHeader()
        try handle.synchronize()
    }

    private func updateHeader() throws {
        let endOffset = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.wavHeader(pcmByteCount: pcmByteCount))
        try handle.seek(toOffset: endOffset)
    }

    private func normalize(_ chunk: AudioChunk) -> AudioChunk {
        let monoSamples = downmixToMono(samples: chunk.samples, channels: chunk.format.channels)
        let samples = resample(
            monoSamples,
            fromSampleRate: chunk.format.sampleRate,
            toSampleRate: outputFormat.sampleRate
        )
        return AudioChunk(
            sequence: chunk.sequence,
            startMs: chunk.startMs,
            endMs: chunk.endMs,
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

    private func pcm16Data(samples: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let scaled = Int16(clamped * Float(Int16.max))
            data.appendLittleEndian(scaled)
        }
        return data
    }

    private static func wavHeader(pcmByteCount: UInt32) -> Data {
        var data = Data()
        let sampleRate = UInt32(16_000)
        let channels = UInt16(1)
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt16(bitsPerSample / 8)
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * UInt32(blockAlign)

        data.appendString("RIFF")
        data.appendLittleEndian(UInt32(36) + pcmByteCount)
        data.appendString("WAVE")
        data.appendString("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channels)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(byteRate)
        data.appendLittleEndian(blockAlign)
        data.appendLittleEndian(bitsPerSample)
        data.appendString("data")
        data.appendLittleEndian(pcmByteCount)
        return data
    }
}
