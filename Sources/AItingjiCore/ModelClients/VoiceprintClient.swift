import Foundation

public struct VoiceprintResult: Equatable, Sendable {
    public var embedding: [Double]
    public var confidence: Double

    public init(embedding: [Double], confidence: Double = 0) {
        self.embedding = embedding
        self.confidence = confidence
    }
}

public protocol VoiceprintClient: Sendable {
    func identify(chunk: AudioChunk) async throws -> VoiceprintResult
}

public struct MockVoiceprintClient: VoiceprintClient {
    public var embedding: [Double]
    public var confidence: Double

    public init(embedding: [Double] = [1, 0, 0], confidence: Double = 0.9) {
        self.embedding = embedding
        self.confidence = confidence
    }

    public func identify(chunk: AudioChunk) async throws -> VoiceprintResult {
        VoiceprintResult(embedding: embedding, confidence: confidence)
    }
}

public struct BuiltInVoiceprintClient: VoiceprintClient {
    public init() {}

    public func identify(chunk: AudioChunk) async throws -> VoiceprintResult {
        let embedding = BuiltInVoiceprintEmbedding.extract(samples: chunk.samples)
        let confidence = BuiltInVoiceprintEmbedding.isSilent(samples: chunk.samples) ? 0 : 0.75
        return VoiceprintResult(embedding: embedding, confidence: confidence)
    }
}

enum BuiltInVoiceprintEmbedding {
    static let dimension = 64

    static func extract(samples: [Float]) -> [Double] {
        guard !samples.isEmpty else {
            return Array(repeating: 0, count: dimension)
        }

        var features: [Double] = []
        features.reserveCapacity(dimension)

        let globalRMS = rms(samples[...])
        let globalMean = mean(samples[...])
        let globalZeroCrossing = zeroCrossingRate(samples[...])
        let dynamicRange = percentileMagnitude(samples, percentile: 0.95) - percentileMagnitude(samples, percentile: 0.25)
        let frameStats = frameStatistics(samples: samples)

        features.append(contentsOf: [
            globalRMS,
            abs(globalMean),
            globalZeroCrossing,
            max(0, dynamicRange),
            frameStats.rmsMean,
            frameStats.rmsStdDev,
            frameStats.rmsMax,
            frameStats.zeroCrossingMean,
            frameStats.zeroCrossingStdDev,
            frameStats.energyEntropy
        ])

        let bucketCount = 12
        let bucketSize = max(1, samples.count / bucketCount)
        for bucket in 0..<bucketCount {
            let start = bucket * bucketSize
            let end = min(samples.count, start + bucketSize)
            if start >= samples.count {
                features.append(contentsOf: [0, 0, 0])
                continue
            }

            let window = samples[start..<end]
            features.append(rms(window))
            features.append(abs(mean(window)))
            features.append(zeroCrossingRate(window))
        }

        let bandFeatures = spectralBandFeatures(samples: samples, bands: 18)
        features.append(contentsOf: bandFeatures)

        while features.count < dimension {
            features.append(0)
        }

        return normalize(Array(features.prefix(dimension)))
    }

    static func isSilent(samples: [Float]) -> Bool {
        rms(samples[...]) < 0.0001
    }

    private static func zeroCrossingRate(_ samples: ArraySlice<Float>) -> Double {
        guard samples.count > 1 else {
            return 0
        }
        var previous = samples.first ?? 0
        var crossings = 0
        for sample in samples.dropFirst() {
            if (previous < 0 && sample >= 0) || (previous >= 0 && sample < 0) {
                crossings += 1
            }
            previous = sample
        }
        return Double(crossings) / Double(samples.count - 1)
    }

    private static func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else {
            return 0
        }
        let energy = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)
        return sqrt(energy)
    }

    private static func mean(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else {
            return 0
        }
        return samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
    }

    private static func percentileMagnitude(_ samples: [Float], percentile: Double) -> Double {
        let magnitudes = samples.map { abs(Double($0)) }.sorted()
        guard !magnitudes.isEmpty else {
            return 0
        }
        let index = min(magnitudes.count - 1, max(0, Int(Double(magnitudes.count - 1) * percentile)))
        return magnitudes[index]
    }

    private static func spectralBandFeatures(samples: [Float], bands: Int) -> [Double] {
        guard !samples.isEmpty, bands > 0 else {
            return []
        }
        let maxSamples = min(samples.count, 512)
        let stride = max(1, maxSamples / bands)
        var features: [Double] = []
        features.reserveCapacity(bands)

        for band in 0..<bands {
            let frequency = Double(band + 1)
            var real = 0.0
            var imaginary = 0.0
            var index = 0
            while index < maxSamples {
                let angle = 2.0 * Double.pi * frequency * Double(index) / Double(maxSamples)
                let value = Double(samples[index])
                real += value * cos(angle)
                imaginary -= value * sin(angle)
                index += stride
            }
            features.append(sqrt(real * real + imaginary * imaginary) / Double(maxSamples))
        }
        return features
    }

    private static func frameStatistics(samples: [Float]) -> (
        rmsMean: Double,
        rmsStdDev: Double,
        rmsMax: Double,
        zeroCrossingMean: Double,
        zeroCrossingStdDev: Double,
        energyEntropy: Double
    ) {
        let frameSize = min(max(80, samples.count / 8), 400)
        let hopSize = max(1, frameSize / 2)
        var frameRMS: [Double] = []
        var frameZCR: [Double] = []
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + frameSize)
            let window = samples[start..<end]
            frameRMS.append(rms(window))
            frameZCR.append(zeroCrossingRate(window))
            if end == samples.count {
                break
            }
            start += hopSize
        }

        let totalEnergy = frameRMS.reduce(0) { $0 + $1 * $1 }
        let entropy = frameRMS.reduce(0.0) { partial, value in
            guard totalEnergy > 0 else {
                return partial
            }
            let probability = (value * value) / totalEnergy
            return probability > 0 ? partial - probability * log(probability) : partial
        }

        return (
            rmsMean: average(frameRMS),
            rmsStdDev: stdDev(frameRMS),
            rmsMax: frameRMS.max() ?? 0,
            zeroCrossingMean: average(frameZCR),
            zeroCrossingStdDev: stdDev(frameZCR),
            energyEntropy: entropy
        )
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func stdDev(_ values: [Double]) -> Double {
        guard values.count > 1 else {
            return 0
        }
        let mean = average(values)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return sqrt(variance)
    }

    private static func normalize(_ values: [Double]) -> [Double] {
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else {
            return values
        }
        return values.map { $0 / norm }
    }
}
