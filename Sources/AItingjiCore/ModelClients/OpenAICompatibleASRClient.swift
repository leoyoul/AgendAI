import Foundation

public enum ASRClientError: Error, Equatable, Sendable {
    case missingModel
    case invalidBaseURL
    case invalidResponseStatus(Int, String)
    case missingText
}

public struct OpenAICompatibleASRClient<Uploader: HTTPDataUploading>: ASRClient {
    public var source: ModelSource
    public var uploader: Uploader

    public init(source: ModelSource, uploader: Uploader) {
        self.source = source
        self.uploader = uploader
    }

    public func transcribe(chunk: AudioChunk) async throws -> ASRSegment {
        guard let model = source.selectedModel, !model.isEmpty else {
            throw ASRClientError.missingModel
        }
        guard let url = URL(string: source.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/audio/transcriptions") else {
            throw ASRClientError.invalidBaseURL
        }

        let boundary = "AItingjiBoundary-\(UUID().uuidString)"
        let wavData = WAVEncoder.encode(chunk: chunk)
        let body = MultipartFormData(boundary: boundary)
            .addingField(name: "model", value: model)
            .addingField(name: "language", value: "zh")
            .addingField(name: "temperature", value: "0")
            .addingField(name: "response_format", value: "json")
            .addingFile(
                name: "file",
                filename: "chunk-\(chunk.sequence).wav",
                contentType: "audio/wav",
                data: wavData
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
            throw ASRClientError.invalidResponseStatus(response.statusCode, message)
        }

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: response.data)
        guard let text = decoded.resolvedText else {
            throw ASRClientError.missingText
        }
        return ASRSegment(startMs: chunk.startMs, endMs: chunk.endMs, text: text)
    }
}

private struct TranscriptionResponse: Decodable {
    var text: String?
    var segments: [TranscriptionResponseSegment]?

    var resolvedText: String? {
        if let text {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
            if let segmentText = joinedSegmentText {
                return segmentText
            }
            return ""
        }
        return joinedSegmentText
    }

    private var joinedSegmentText: String? {
        let parts = segments?
            .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        guard !parts.isEmpty else {
            return nil
        }
        return parts.joined(separator: " ")
    }
}

private struct TranscriptionResponseSegment: Decodable {
    var text: String?
}

extension ASRClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingModel:
            return "ASR 模型未选择，请先选择模型。"
        case .invalidBaseURL:
            return "ASR 服务地址无效，请检查 baseURL。"
        case .invalidResponseStatus(let statusCode, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "ASR 服务返回错误 \(statusCode)。"
            }
            return "ASR 服务返回错误 \(statusCode)：\(trimmed)"
        case .missingText:
            return "ASR 返回格式缺少 text 字段。"
        }
    }
}
