import Foundation

public enum VoiceprintClientError: Error, Equatable, Sendable {
    case missingModel
    case invalidBaseURL
    case invalidResponseStatus(Int, String)
    case missingEmbedding
}

public struct CompatibleVoiceprintClient<Uploader: HTTPDataUploading>: VoiceprintClient {
    public var source: ModelSource
    public var uploader: Uploader

    public init(source: ModelSource, uploader: Uploader) {
        self.source = source
        self.uploader = uploader
    }

    public func identify(chunk: AudioChunk) async throws -> VoiceprintResult {
        guard let model = source.selectedModel, !model.isEmpty else {
            throw VoiceprintClientError.missingModel
        }
        guard let url = URL(string: source.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/voiceprint/identify") else {
            throw VoiceprintClientError.invalidBaseURL
        }

        let boundary = "AItingjiBoundary-\(UUID().uuidString)"
        let body = MultipartFormData(boundary: boundary)
            .addingField(name: "model", value: model)
            .addingFile(
                name: "file",
                filename: "chunk-\(chunk.sequence).wav",
                contentType: "audio/wav",
                data: WAVEncoder.encode(chunk: chunk)
            )
            .data()

        var headers = ["Content-Type": "multipart/form-data; boundary=\(boundary)"]
        if !source.apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(source.apiKey)"
        }

        let response = try await uploader.upload(
            request: HTTPUploadRequest(url: url, headers: headers, body: body)
        )
        guard (200..<300).contains(response.statusCode) else {
            let message = String(decoding: response.data, as: UTF8.self)
            throw VoiceprintClientError.invalidResponseStatus(response.statusCode, message)
        }

        let decoded = try JSONDecoder().decode(VoiceprintResponse.self, from: response.data)
        guard let embedding = decoded.embedding, !embedding.isEmpty else {
            throw VoiceprintClientError.missingEmbedding
        }
        return VoiceprintResult(embedding: embedding, confidence: decoded.confidence ?? 0)
    }
}

private struct VoiceprintResponse: Decodable {
    var embedding: [Double]?
    var confidence: Double?
}
