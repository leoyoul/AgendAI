import Foundation

public struct UnknownSpeaker: Equatable, Sendable {
    public let index: Int
    public let label: String
    public let embedding: [Double]

    public init(index: Int, label: String, embedding: [Double]) {
        self.index = index
        self.label = label
        self.embedding = embedding
    }
}

public func cosineSimilarity(_ left: [Double], _ right: [Double]) -> Double {
    guard left.count == right.count, !left.isEmpty else {
        return 0
    }

    let dot = zip(left, right).reduce(0) { partial, pair in
        partial + pair.0 * pair.1
    }
    let leftNorm = sqrt(left.reduce(0) { $0 + $1 * $1 })
    let rightNorm = sqrt(right.reduce(0) { $0 + $1 * $1 })
    guard leftNorm > 0, rightNorm > 0 else {
        return 0
    }
    return dot / (leftNorm * rightNorm)
}

public struct UnknownSpeakerAssigner: Sendable {
    public let threshold: Double
    private var storage: [UnknownSpeaker]

    public init(threshold: Double = 0.68, speakers: [UnknownSpeaker] = []) {
        self.threshold = threshold
        self.storage = speakers
    }

    public var speakers: [UnknownSpeaker] {
        storage
    }

    public mutating func assign(embedding: [Double]) -> UnknownSpeaker {
        let normalizedEmbedding = normalized(embedding)
        let best = storage
            .enumerated()
            .map { offset, speaker in
                (offset, speaker, cosineSimilarity(normalizedEmbedding, speaker.embedding))
            }
            .max { left, right in
                left.2 < right.2
            }

        if let best, best.2 >= threshold {
            let updated = UnknownSpeaker(
                index: best.1.index,
                label: best.1.label,
                embedding: smoothedEmbedding(old: best.1.embedding, new: normalizedEmbedding)
            )
            storage[best.0] = updated
            return updated
        }

        let index = storage.count + 1
        let speaker = UnknownSpeaker(
            index: index,
            label: "未知发言人 \(index)",
            embedding: normalizedEmbedding
        )
        storage.append(speaker)
        return speaker
    }

    private func smoothedEmbedding(old: [Double], new: [Double]) -> [Double] {
        guard old.count == new.count, !old.isEmpty else { return new }
        let alpha = 0.75
        return normalized(zip(old, new).map { alpha * $0.0 + (1 - alpha) * $0.1 })
    }

    private func normalized(_ embedding: [Double]) -> [Double] {
        let norm = sqrt(embedding.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return embedding }
        return embedding.map { $0 / norm }
    }
}
