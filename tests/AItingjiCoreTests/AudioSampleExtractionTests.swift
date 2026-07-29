import AItingjiCore
import AVFoundation
import Testing

@Test func audioSampleExtractorReadsFloatPCMBuffer() throws {
    let format = try #require(
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
    )
    let buffer = try #require(
        AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)
    )
    buffer.frameLength = 4
    let channel = try #require(buffer.floatChannelData?[0])
    channel[0] = 0.1
    channel[1] = -0.2
    channel[2] = 0.3
    channel[3] = -0.4

    let samples = AudioSampleExtractor.extractSamples(from: buffer)

    #expect(samples == [0.1, -0.2, 0.3, -0.4])
}
