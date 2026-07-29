import Foundation

public enum SpeechQualityDecision: String, Equatable, Sendable {
    case skipTranscription
    case transcriptionOnly
    case voiceprintEligible
}

public struct SpeechQualityAnalysis: Equatable, Sendable {
    public var durationMs: Int
    public var rms: Double
    public var peak: Double
    public var activeRatio: Double
    public var clippingRatio: Double
    public var zeroCrossingRate: Double
    public var qualityScore: Double
    public var decision: SpeechQualityDecision
    public var reason: String

    public var shouldTranscribe: Bool {
        decision != .skipTranscription
    }

    public var canUseForVoiceprint: Bool {
        decision == .voiceprintEligible
    }

    public init(
        durationMs: Int,
        rms: Double,
        peak: Double,
        activeRatio: Double,
        clippingRatio: Double,
        zeroCrossingRate: Double,
        qualityScore: Double,
        decision: SpeechQualityDecision,
        reason: String
    ) {
        self.durationMs = durationMs
        self.rms = rms
        self.peak = peak
        self.activeRatio = activeRatio
        self.clippingRatio = clippingRatio
        self.zeroCrossingRate = zeroCrossingRate
        self.qualityScore = qualityScore
        self.decision = decision
        self.reason = reason
    }
}

public enum SpeechQualityGate {
    public static let minimumTranscriptionDurationMs = 300
    public static let minimumVoiceprintDurationMs = 1_500
    public static let silenceRMSThreshold = 0.003
    public static let minimumVoiceprintRMSThreshold = 0.008
    public static let activeSampleThreshold: Float = 0.012
    public static let minimumActiveRatio = 0.03
    public static let clippingSampleThreshold: Float = 0.98
    public static let maximumVoiceprintClippingRatio = 0.015
    public static let maximumVoiceprintZeroCrossingRate = 0.28
    public static let maximumSamplesToInspect = 48_000

    public static func analyze(_ chunk: AudioChunk) -> SpeechQualityAnalysis {
        let samples = chunk.samples
        let durationMs = max(0, chunk.endMs - chunk.startMs)
        guard !samples.isEmpty, durationMs >= minimumTranscriptionDurationMs else {
            return emptyAnalysis(
                durationMs: durationMs,
                decision: .skipTranscription,
                reason: "片段过短"
            )
        }

        let stride = max(1, samples.count / maximumSamplesToInspect)
        var inspected = 0
        var active = 0
        var clipped = 0
        var sumSquares = 0.0
        var peak = 0.0
        var crossings = 0
        var previousSign: Int?

        for index in Swift.stride(from: 0, to: samples.count, by: stride) {
            let value = samples[index]
            let magnitude = Double(abs(value))
            inspected += 1
            sumSquares += Double(value) * Double(value)
            peak = max(peak, magnitude)
            if abs(value) >= activeSampleThreshold {
                active += 1
                let sign = value >= 0 ? 1 : -1
                if let previousSign, previousSign != sign {
                    crossings += 1
                }
                previousSign = sign
            }
            if abs(value) >= clippingSampleThreshold {
                clipped += 1
            }
        }

        guard inspected > 0 else {
            return emptyAnalysis(
                durationMs: durationMs,
                decision: .skipTranscription,
                reason: "片段为空"
            )
        }

        let rms = (sumSquares / Double(inspected)).squareRoot()
        let activeRatio = Double(active) / Double(inspected)
        let clippingRatio = Double(clipped) / Double(inspected)
        let zeroCrossingRate = active > 1 ? Double(crossings) / Double(active - 1) : 0
        let score = qualityScore(
            rms: rms,
            activeRatio: activeRatio,
            clippingRatio: clippingRatio,
            zeroCrossingRate: zeroCrossingRate
        )

        if rms < silenceRMSThreshold || activeRatio < minimumActiveRatio {
            return analysis(
                durationMs: durationMs,
                rms: rms,
                peak: peak,
                activeRatio: activeRatio,
                clippingRatio: clippingRatio,
                zeroCrossingRate: zeroCrossingRate,
                qualityScore: score,
                decision: .skipTranscription,
                reason: "静音或环境底噪"
            )
        }

        if durationMs < minimumVoiceprintDurationMs {
            return analysis(
                durationMs: durationMs,
                rms: rms,
                peak: peak,
                activeRatio: activeRatio,
                clippingRatio: clippingRatio,
                zeroCrossingRate: zeroCrossingRate,
                qualityScore: score,
                decision: .transcriptionOnly,
                reason: "片段太短，不用于声纹匹配"
            )
        }

        if rms < minimumVoiceprintRMSThreshold {
            return analysis(
                durationMs: durationMs,
                rms: rms,
                peak: peak,
                activeRatio: activeRatio,
                clippingRatio: clippingRatio,
                zeroCrossingRate: zeroCrossingRate,
                qualityScore: score,
                decision: .transcriptionOnly,
                reason: "音量过低，不用于声纹匹配"
            )
        }

        if clippingRatio > maximumVoiceprintClippingRatio {
            return analysis(
                durationMs: durationMs,
                rms: rms,
                peak: peak,
                activeRatio: activeRatio,
                clippingRatio: clippingRatio,
                zeroCrossingRate: zeroCrossingRate,
                qualityScore: score,
                decision: .transcriptionOnly,
                reason: "削波失真，不用于声纹匹配"
            )
        }

        if zeroCrossingRate > maximumVoiceprintZeroCrossingRate && activeRatio > 0.55 {
            return analysis(
                durationMs: durationMs,
                rms: rms,
                peak: peak,
                activeRatio: activeRatio,
                clippingRatio: clippingRatio,
                zeroCrossingRate: zeroCrossingRate,
                qualityScore: score,
                decision: .transcriptionOnly,
                reason: "噪声或重叠风险高，不用于声纹匹配"
            )
        }

        return analysis(
            durationMs: durationMs,
            rms: rms,
            peak: peak,
            activeRatio: activeRatio,
            clippingRatio: clippingRatio,
            zeroCrossingRate: zeroCrossingRate,
            qualityScore: score,
            decision: .voiceprintEligible,
            reason: "可用于声纹匹配"
        )
    }

    private static func qualityScore(
        rms: Double,
        activeRatio: Double,
        clippingRatio: Double,
        zeroCrossingRate: Double
    ) -> Double {
        var score = 1.0
        if rms < minimumVoiceprintRMSThreshold {
            score -= min(0.35, (minimumVoiceprintRMSThreshold - rms) / minimumVoiceprintRMSThreshold * 0.35)
        }
        if activeRatio < 0.20 {
            score -= min(0.25, (0.20 - activeRatio) / 0.20 * 0.25)
        }
        score -= min(0.35, clippingRatio / maximumVoiceprintClippingRatio * 0.35)
        if zeroCrossingRate > 0.18 {
            score -= min(0.25, (zeroCrossingRate - 0.18) / 0.25 * 0.25)
        }
        return min(1, max(0, score))
    }

    private static func emptyAnalysis(
        durationMs: Int,
        decision: SpeechQualityDecision,
        reason: String
    ) -> SpeechQualityAnalysis {
        SpeechQualityAnalysis(
            durationMs: durationMs,
            rms: 0,
            peak: 0,
            activeRatio: 0,
            clippingRatio: 0,
            zeroCrossingRate: 0,
            qualityScore: 0,
            decision: decision,
            reason: reason
        )
    }

    private static func analysis(
        durationMs: Int,
        rms: Double,
        peak: Double,
        activeRatio: Double,
        clippingRatio: Double,
        zeroCrossingRate: Double,
        qualityScore: Double,
        decision: SpeechQualityDecision,
        reason: String
    ) -> SpeechQualityAnalysis {
        SpeechQualityAnalysis(
            durationMs: durationMs,
            rms: rms,
            peak: peak,
            activeRatio: activeRatio,
            clippingRatio: clippingRatio,
            zeroCrossingRate: zeroCrossingRate,
            qualityScore: qualityScore,
            decision: decision,
            reason: reason
        )
    }
}
