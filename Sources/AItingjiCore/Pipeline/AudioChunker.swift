import Foundation

public struct AudioChunker: Sendable {
    public let format: AudioFormatDescription
    public let chunkDurationMs: Int

    public init(format: AudioFormatDescription, chunkDurationMs: Int = 1000) {
        precondition(chunkDurationMs > 0)
        self.format = format
        self.chunkDurationMs = chunkDurationMs
    }

    public func makeChunks(samples: [Float], startingAtMs: Int = 0) -> [AudioChunk] {
        let samplesPerChunk = max(1, Int(format.sampleRate) * format.channels * chunkDurationMs / 1000)
        var chunks: [AudioChunk] = []
        var offset = 0
        var sequence = 0

        while offset < samples.count {
            let end = min(offset + samplesPerChunk, samples.count)
            let chunkSamples = Array(samples[offset..<end])
            let startMs = startingAtMs + Int(Double(offset) / Double(format.sampleRate * Double(format.channels)) * 1000)
            let durationMs = Int(Double(chunkSamples.count) / Double(format.sampleRate * Double(format.channels)) * 1000)
            chunks.append(
                AudioChunk(
                    sequence: sequence,
                    startMs: startMs,
                    endMs: startMs + durationMs,
                    samples: chunkSamples,
                    format: format
                )
            )
            offset = end
            sequence += 1
        }

        return chunks
    }

    public func peakLevel(samples: [Float]) -> Float {
        samples.map { abs($0) }.max() ?? 0
    }
}
