import AItingjiCore
import Testing

@Test
func audioChunkAccumulatorEmitsOnlyAfterEnoughSmallChunks() {
    let format = AudioFormatDescription(sampleRate: 4, channels: 1)
    var accumulator = AudioChunkAccumulator(targetDurationMs: 1000)

    let first = accumulator.append(
        AudioChunk(
            sequence: 10,
            startMs: 2_000,
            endMs: 2_500,
            samples: [0.1, 0.2],
            format: format
        )
    )
    let second = accumulator.append(
        AudioChunk(
            sequence: 11,
            startMs: 2_500,
            endMs: 3_000,
            samples: [0.3, 0.4],
            format: format
        )
    )

    #expect(first == nil)
    #expect(second?.sequence == 10)
    #expect(second?.startMs == 2_000)
    #expect(second?.endMs == 3_000)
    #expect(second?.samples == [0.1, 0.2, 0.3, 0.4])
    #expect(accumulator.bufferedSampleCount == 0)
}

@Test
func audioChunkAccumulatorKeepsRemainderForNextEmission() {
    let format = AudioFormatDescription(sampleRate: 4, channels: 1)
    var accumulator = AudioChunkAccumulator(targetDurationMs: 1000)

    let output = accumulator.append(
        AudioChunk(
            sequence: 3,
            startMs: 1_000,
            endMs: 2_250,
            samples: [0, 1, 2, 3, 4],
            format: format
        )
    )

    #expect(output?.samples == [0, 1, 2, 3])
    #expect(output?.endMs == 2_000)
    #expect(accumulator.bufferedSampleCount == 1)
}

@Test
func audioChunkAccumulatorFlushesRemainderBeforePauseOrStop() {
    let format = AudioFormatDescription(sampleRate: 4, channels: 1)
    var accumulator = AudioChunkAccumulator(targetDurationMs: 1000)

    let output = accumulator.append(
        AudioChunk(
            sequence: 7,
            startMs: 5_000,
            endMs: 5_500,
            samples: [0.1, 0.2],
            format: format
        )
    )
    let flushed = accumulator.flush()

    #expect(output == nil)
    #expect(flushed?.sequence == 7)
    #expect(flushed?.startMs == 5_000)
    #expect(flushed?.endMs == 5_500)
    #expect(flushed?.samples == [0.1, 0.2])
    #expect(accumulator.bufferedSampleCount == 0)
}

@Test
func audioChunkAccumulatorSupportsLongerRealtimeASRWindow() {
    let format = AudioFormatDescription(sampleRate: 16_000, channels: 1)
    var accumulator = AudioChunkAccumulator(targetDurationMs: 10_000)

    let first = accumulator.append(
        AudioChunk(
            sequence: 1,
            startMs: 0,
            endMs: 3_000,
            samples: Array(repeating: 0.1, count: 48_000),
            format: format
        )
    )
    let second = accumulator.append(
        AudioChunk(
            sequence: 2,
            startMs: 3_000,
            endMs: 10_000,
            samples: Array(repeating: 0.1, count: 112_000),
            format: format
        )
    )

    #expect(first == nil)
    #expect(second?.startMs == 0)
    #expect(second?.endMs == 10_000)
    #expect(second?.samples.count == 160_000)
}

@Test
func audioChunkAccumulatorFlushesOldFormatBeforeAcceptingNewFormat() {
    let oldFormat = AudioFormatDescription(sampleRate: 4, channels: 1)
    let newFormat = AudioFormatDescription(sampleRate: 8, channels: 1)
    var accumulator = AudioChunkAccumulator(targetDurationMs: 1000)

    let first = accumulator.appendAll(
        AudioChunk(
            sequence: 4,
            startMs: 0,
            endMs: 500,
            samples: [0.1, 0.2],
            format: oldFormat
        )
    )
    let second = accumulator.appendAll(
        AudioChunk(
            sequence: 5,
            startMs: 500,
            endMs: 1_500,
            samples: Array(repeating: 0.3, count: 8),
            format: newFormat
        )
    )

    #expect(first.isEmpty)
    #expect(second.count == 2)
    #expect(second[0].format == oldFormat)
    #expect(second[0].startMs == 0)
    #expect(second[0].endMs == 500)
    #expect(second[0].samples == [0.1, 0.2])
    #expect(second[1].format == newFormat)
    #expect(second[1].startMs == 500)
    #expect(second[1].endMs == 1_500)
    #expect(second[1].samples == Array(repeating: 0.3, count: 8))
}

@Test
func audioChunkAccumulatorDrainsEveryCompleteWindowFromOneLargeBuffer() {
    let format = AudioFormatDescription(sampleRate: 4, channels: 1)
    var accumulator = AudioChunkAccumulator(targetDurationMs: 1000)

    let chunks = accumulator.appendAll(
        AudioChunk(
            sequence: 8,
            startMs: 2_000,
            endMs: 4_000,
            samples: Array(0..<8).map(Float.init),
            format: format
        )
    )

    #expect(chunks.count == 2)
    #expect(chunks.map(\.sequence) == [8, 9])
    #expect(chunks.map(\.startMs) == [2_000, 3_000])
    #expect(chunks.map(\.endMs) == [3_000, 4_000])
    #expect(chunks.map(\.samples) == [[0, 1, 2, 3], [4, 5, 6, 7]])
    #expect(accumulator.bufferedSampleCount == 0)
}
