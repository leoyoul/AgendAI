import Foundation

/// 将底层音频 buffer 聚合为固定时长的 chunk。
///
/// `appendAll(_:)` 会完整返回本次输入产生的所有输出；采集端应使用它，
/// 以便单个底层 buffer 大于目标窗口时也不会遗漏后续完整窗口。
public struct AudioChunkAccumulator: Sendable {
    public let targetDurationMs: Int
    private var bufferedSamples: [Float] = []
    private var bufferedFormat: AudioFormatDescription?
    private var bufferedStartMs = 0
    private var bufferedSequence = 0
    private var readyChunks: [AudioChunk] = []

    public init(targetDurationMs: Int = 1000) {
        precondition(targetDurationMs > 0)
        self.targetDurationMs = targetDurationMs
    }

    public var bufferedSampleCount: Int {
        bufferedSamples.count
    }

    /// 兼容单 chunk 消费方。采集链路应改用 `appendAll(_:)`，避免一次输入产生多个
    /// 完整窗口时只能取到第一个。
    public mutating func append(_ chunk: AudioChunk) -> AudioChunk? {
        readyChunks.append(contentsOf: appendAll(chunk))
        return dequeueReadyChunk()
    }

    /// 追加一个底层 buffer，并返回所有已完成的目标窗口。
    ///
    /// 当格式变化时，先输出旧格式的残余样本，再开始累计新格式样本；绝不混合两种格式。
    public mutating func appendAll(_ chunk: AudioChunk) -> [AudioChunk] {
        guard !chunk.samples.isEmpty else {
            return drainReadyChunks()
        }

        var emitted = drainReadyChunks()
        if let format = bufferedFormat, format != chunk.format, !bufferedSamples.isEmpty {
            if let remainder = flushBufferedChunk() {
                emitted.append(remainder)
            }
        }

        if bufferedSamples.isEmpty {
            bufferedFormat = chunk.format
            bufferedStartMs = chunk.startMs
            bufferedSequence = chunk.sequence
        }
        bufferedSamples.append(contentsOf: chunk.samples)

        guard let format = bufferedFormat else {
            return emitted
        }

        let targetSamples = Self.targetSampleCount(format: format, durationMs: targetDurationMs)
        while bufferedSamples.count >= targetSamples {
            let outputSamples = Array(bufferedSamples.prefix(targetSamples))
            let durationMs = Self.durationMs(sampleCount: outputSamples.count, format: format)
            emitted.append(
                AudioChunk(
                    sequence: bufferedSequence,
                    startMs: bufferedStartMs,
                    endMs: bufferedStartMs + durationMs,
                    samples: outputSamples,
                    format: format
                )
            )

            bufferedSamples.removeFirst(targetSamples)
            if bufferedSamples.isEmpty {
                bufferedFormat = nil
            } else {
                bufferedStartMs += durationMs
                bufferedSequence += 1
            }
        }

        return emitted
    }

    public mutating func reset() {
        bufferedSamples.removeAll(keepingCapacity: true)
        bufferedFormat = nil
        bufferedStartMs = 0
        bufferedSequence = 0
        readyChunks.removeAll(keepingCapacity: true)
    }

    /// 兼容单 chunk 消费方；若有多个待取输出，可重复调用，或改用 `flushAll()`。
    public mutating func flush() -> AudioChunk? {
        if let ready = dequeueReadyChunk() {
            return ready
        }
        return flushBufferedChunk()
    }

    /// 返回所有已完成窗口及当前残余，供暂停/停止时完整写出。
    public mutating func flushAll() -> [AudioChunk] {
        var emitted = drainReadyChunks()
        if let remainder = flushBufferedChunk() {
            emitted.append(remainder)
        }
        return emitted
    }

    private mutating func flushBufferedChunk() -> AudioChunk? {
        guard !bufferedSamples.isEmpty, let format = bufferedFormat else {
            return nil
        }
        let outputSamples = bufferedSamples
        let durationMs = Self.durationMs(sampleCount: outputSamples.count, format: format)
        let output = AudioChunk(
            sequence: bufferedSequence,
            startMs: bufferedStartMs,
            endMs: bufferedStartMs + durationMs,
            samples: outputSamples,
            format: format
        )
        bufferedSamples.removeAll(keepingCapacity: true)
        bufferedFormat = nil
        bufferedStartMs = 0
        bufferedSequence = 0
        return output
    }

    private mutating func dequeueReadyChunk() -> AudioChunk? {
        guard !readyChunks.isEmpty else {
            return nil
        }
        return readyChunks.removeFirst()
    }

    private mutating func drainReadyChunks() -> [AudioChunk] {
        let chunks = readyChunks
        readyChunks.removeAll(keepingCapacity: true)
        return chunks
    }

    private static func targetSampleCount(format: AudioFormatDescription, durationMs: Int) -> Int {
        let samplesPerSecond = max(1, Int(format.sampleRate.rounded()) * max(1, format.channels))
        return max(1, samplesPerSecond * durationMs / 1000)
    }

    private static func durationMs(sampleCount: Int, format: AudioFormatDescription) -> Int {
        let samplesPerSecond = max(1, format.sampleRate * Double(max(1, format.channels)))
        return Int(Double(sampleCount) / samplesPerSecond * 1000)
    }
}
