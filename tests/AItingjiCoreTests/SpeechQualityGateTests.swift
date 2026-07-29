import AItingjiCore
import Foundation
import Testing

@Test
func speechQualityGateSkipsSilence() {
    let chunk = makeQualityChunk(samples: Array(repeating: 0, count: 16_000), durationMs: 1_000)

    let analysis = SpeechQualityGate.analyze(chunk)

    #expect(analysis.decision == .skipTranscription)
    #expect(!analysis.shouldTranscribe)
    #expect(!analysis.canUseForVoiceprint)
}

@Test
func speechQualityGateTranscribesShortSpeechButRejectsVoiceprint() {
    let samples = sineSamples(durationMs: 800, amplitude: 0.08)
    let chunk = makeQualityChunk(samples: samples, durationMs: 800)

    let analysis = SpeechQualityGate.analyze(chunk)

    #expect(analysis.decision == .transcriptionOnly)
    #expect(analysis.shouldTranscribe)
    #expect(!analysis.canUseForVoiceprint)
}

@Test
func speechQualityGateAcceptsCleanLongSpeechForVoiceprint() {
    let samples = sineSamples(durationMs: 2_000, amplitude: 0.08)
    let chunk = makeQualityChunk(samples: samples, durationMs: 2_000)

    let analysis = SpeechQualityGate.analyze(chunk)

    #expect(analysis.decision == .voiceprintEligible)
    #expect(analysis.shouldTranscribe)
    #expect(analysis.canUseForVoiceprint)
    #expect(analysis.qualityScore > 0.6)
}

@Test
func speechQualityGateRejectsClippedAudioForVoiceprintOnly() {
    let samples = (0..<32_000).map { index in
        index % 2 == 0 ? Float(1.0) : Float(-1.0)
    }
    let chunk = makeQualityChunk(samples: samples, durationMs: 2_000)

    let analysis = SpeechQualityGate.analyze(chunk)

    #expect(analysis.decision == .transcriptionOnly)
    #expect(analysis.shouldTranscribe)
    #expect(!analysis.canUseForVoiceprint)
}

@Test
func speechQualityGateRejectsHighCrossingNoiseForVoiceprintOnly() {
    let samples = (0..<32_000).map { index in
        Float(index % 2 == 0 ? 0.06 : -0.06)
    }
    let chunk = makeQualityChunk(samples: samples, durationMs: 2_000)

    let analysis = SpeechQualityGate.analyze(chunk)

    #expect(analysis.decision == .transcriptionOnly)
    #expect(analysis.shouldTranscribe)
    #expect(!analysis.canUseForVoiceprint)
    #expect(analysis.zeroCrossingRate > SpeechQualityGate.maximumVoiceprintZeroCrossingRate)
}

private func makeQualityChunk(samples: [Float], durationMs: Int) -> AudioChunk {
    AudioChunk(
        sequence: 1,
        startMs: 0,
        endMs: durationMs,
        samples: samples,
        format: AudioFormatDescription(sampleRate: 16_000, channels: 1)
    )
}

private func sineSamples(durationMs: Int, amplitude: Float) -> [Float] {
    let sampleRate = 16_000.0
    let count = Int(sampleRate * Double(durationMs) / 1_000)
    return (0..<count).map { index in
        amplitude * Float(sin(2 * Double.pi * 220 * Double(index) / sampleRate))
    }
}
