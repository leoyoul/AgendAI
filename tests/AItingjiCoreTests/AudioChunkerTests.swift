import AItingjiCore
import Testing

@Test
func audioChunkerSplitsSamplesByDuration() {
    let format = AudioFormatDescription(sampleRate: 4, channels: 1)
    let chunker = AudioChunker(format: format, chunkDurationMs: 500)
    let chunks = chunker.makeChunks(samples: [0, 1, 2, 3, 4], startingAtMs: 1000)

    #expect(chunks.count == 3)
    #expect(chunks[0].sequence == 0)
    #expect(chunks[0].startMs == 1000)
    #expect(chunks[0].endMs == 1500)
    #expect(chunks[0].samples == [0, 1])
    #expect(chunks[1].startMs == 1500)
    #expect(chunks[1].endMs == 2000)
    #expect(chunks[2].samples == [4])
}

@Test
func audioChunkerCalculatesPeakLevel() {
    let chunker = AudioChunker(format: AudioFormatDescription(sampleRate: 16_000, channels: 1))

    #expect(chunker.peakLevel(samples: [-0.2, 0.4, -0.8]) == 0.8)
    #expect(chunker.peakLevel(samples: []) == 0)
}
