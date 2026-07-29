import AItingjiCore
import Foundation
import Testing

@Test
func wavAudioSegmentReaderExtractsRequestedTimeRange() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wav-segment-reader-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    let writer = try MeetingAudioWriter(url: url)
    let samples = (0..<16_000).map { index in
        Float(index) / 16_000
    }
    try writer.append(
        AudioChunk(
            sequence: 0,
            startMs: 0,
            endMs: 1_000,
            samples: samples,
            format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
        )
    )
    try writer.finish()

    let chunk = try WAVAudioSegmentReader.readChunk(
        from: url,
        startMs: 250,
        endMs: 500,
        sequence: 7
    )

    #expect(chunk.sequence == 7)
    #expect(chunk.startMs == 250)
    #expect(chunk.endMs == 500)
    #expect(chunk.samples.count == 4_000)
    #expect(abs(chunk.samples[0] - 0.25) < 0.001)
    try? FileManager.default.removeItem(at: url)
}

@Test
func wavAudioSegmentReaderReadsDurationMs() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wav-reader-duration-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    let writer = try MeetingAudioWriter(url: url)
    try writer.append(
        AudioChunk(
            sequence: 0,
            startMs: 0,
            endMs: 1_000,
            samples: Array(repeating: 0.1, count: 16_000),
            format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
        )
    )
    try writer.finish()

    let durationMs = try WAVAudioSegmentReader.durationMs(from: url)

    #expect(durationMs == 1_000)
    try? FileManager.default.removeItem(at: url)
}

@Test
func wavAudioSegmentReaderReadsChunksWithSingleFileLoadSemantics() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wav-reader-chunks-\(UUID().uuidString)")
        .appendingPathExtension("wav")
    let writer = try MeetingAudioWriter(url: url)
    try writer.append(
        AudioChunk(
            sequence: 0,
            startMs: 0,
            endMs: 2_500,
            samples: Array(repeating: 0.1, count: 40_000),
            format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
        )
    )
    try writer.finish()

    let chunks = try WAVAudioSegmentReader.readChunks(
        from: url,
        chunkDurationMs: 1_000,
        startingSequence: 5
    )

    #expect(chunks.map(\.sequence) == [5, 6, 7])
    #expect(chunks.map(\.startMs) == [0, 1_000, 2_000])
    #expect(chunks.map(\.endMs) == [1_000, 2_000, 2_500])
    #expect(chunks.map(\.samples.count) == [16_000, 16_000, 8_000])
    try? FileManager.default.removeItem(at: url)
}
