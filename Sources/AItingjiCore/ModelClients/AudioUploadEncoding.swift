import Foundation

struct MultipartFormData {
    private let boundary: String
    private var parts: [Data] = []

    init(boundary: String) {
        self.boundary = boundary
    }

    func addingField(name: String, value: String) -> MultipartFormData {
        var copy = self
        var part = Data()
        part.appendString("--\(boundary)\r\n")
        part.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        part.appendString("\(value)\r\n")
        copy.parts.append(part)
        return copy
    }

    func addingFile(name: String, filename: String, contentType: String, data: Data) -> MultipartFormData {
        var copy = self
        var part = Data()
        part.appendString("--\(boundary)\r\n")
        part.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        part.appendString("Content-Type: \(contentType)\r\n\r\n")
        part.append(data)
        part.appendString("\r\n")
        copy.parts.append(part)
        return copy
    }

    func data() -> Data {
        var body = Data()
        for part in parts {
            body.append(part)
        }
        body.appendString("--\(boundary)--\r\n")
        return body
    }
}

public enum WAVEncoder {
    public static let outputSampleRate: Double = 16_000
    public static let outputChannels = 1
    private static let targetPeak: Float = 0.85
    private static let maximumGain: Float = 8

    public static func encode(chunk: AudioChunk) -> Data {
        var data = Data()
        let samples = normalizedSamples(for: chunk)
        let sampleRate = UInt32(outputSampleRate)
        let channels = UInt16(outputChannels)
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = UInt16(bitsPerSample / 8)
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * UInt32(blockAlign)
        let pcmData = pcm16Data(samples: samples)
        let riffSize = UInt32(36 + pcmData.count)

        data.appendString("RIFF")
        data.appendLittleEndian(riffSize)
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
        data.appendLittleEndian(UInt32(pcmData.count))
        data.append(pcmData)
        return data
    }

    private static func normalizedSamples(for chunk: AudioChunk) -> [Float] {
        let mono = downmixToMono(samples: chunk.samples, channels: chunk.format.channels)
        let resampled = resample(
            mono,
            fromSampleRate: chunk.format.sampleRate,
            toSampleRate: outputSampleRate
        )
        let peak = resampled.map { abs($0) }.max() ?? 0
        guard peak > 0 else {
            return resampled
        }
        let gain = min(maximumGain, targetPeak / peak)
        return resampled.map { max(-1, min(1, $0 * gain)) }
    }

    private static func downmixToMono(samples: [Float], channels: Int) -> [Float] {
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

    private static func resample(_ samples: [Float], fromSampleRate: Double, toSampleRate: Double) -> [Float] {
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

    private static func pcm16Data(samples: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let scaled = Int16(clamped * Float(Int16.max))
            data.appendLittleEndian(scaled)
        }
        return data
    }
}

extension Data {
    mutating func appendString(_ value: String) {
        append(Data(value.utf8))
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt16>.size))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<UInt32>.size))
    }

    mutating func appendLittleEndian(_ value: Int16) {
        var littleEndian = value.littleEndian
        append(Data(bytes: &littleEndian, count: MemoryLayout<Int16>.size))
    }
}
