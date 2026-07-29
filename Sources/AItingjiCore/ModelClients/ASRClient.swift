import Foundation

public struct ASRSegment: Equatable, Sendable {
    public var startMs: Int
    public var endMs: Int
    public var text: String

    public init(startMs: Int, endMs: Int, text: String) {
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
    }
}

public protocol ASRClient: Sendable {
    func transcribe(chunk: AudioChunk) async throws -> ASRSegment
}

public struct MockASRClient: ASRClient {
    public var text: String

    public init(text: String = "这是一段模拟转写") {
        self.text = text
    }

    public func transcribe(chunk: AudioChunk) async throws -> ASRSegment {
        ASRSegment(startMs: chunk.startMs, endMs: chunk.endMs, text: text)
    }
}
