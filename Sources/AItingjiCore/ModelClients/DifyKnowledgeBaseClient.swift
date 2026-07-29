import Foundation

public struct DifyHTTPResponse: Equatable, Sendable {
    public var data: Data
    public var statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol DifyHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> DifyHTTPResponse
}

public struct URLSessionDifyHTTPTransport: DifyHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = HTTPSessionFactory.shared()) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> DifyHTTPResponse {
        let (data, response) = try await session.data(for: request)
        return DifyHTTPResponse(
            data: data,
            statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0
        )
    }
}

public enum DifyKnowledgeBaseClientError: Error, Equatable, LocalizedError, Sendable {
    case disabled
    case invalidBaseURL
    case emptyAPIKey
    case invalidAPIKey
    case invalidKnowledgeBaseID
    case emptyQuery
    case queryTooLong(maximum: Int)
    case timeout
    case transport(String)
    case httpStatus(Int)
    case api(statusCode: Int, code: String, message: String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .disabled:
            "Dify 知识库未启用"
        case .invalidBaseURL:
            "Dify 服务地址无效"
        case .emptyAPIKey:
            "Dify API Key 为空"
        case .invalidAPIKey:
            "Dify API Key 格式无效"
        case .invalidKnowledgeBaseID:
            "Dify 知识库 ID 无效"
        case .emptyQuery:
            "知识库检索问题不能为空"
        case let .queryTooLong(maximum):
            "知识库检索问题不能超过 \(maximum) 个字符"
        case .timeout:
            "Dify 服务请求超时"
        case let .transport(message):
            "Dify 服务连接失败：\(message)"
        case let .httpStatus(statusCode):
            "Dify 服务返回 HTTP \(statusCode)"
        case let .api(statusCode, code, message):
            "Dify API 错误 \(statusCode)（\(code)）：\(message)"
        case .invalidResponse:
            "Dify 服务响应格式无效"
        }
    }
}

public struct DifyKnowledgeBaseClient<Transport: DifyHTTPTransport>: Sendable {
    public static var maximumQueryLength: Int { 250 }

    public var configuration: DifyKnowledgeBaseConfiguration
    public var transport: Transport

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(configuration: DifyKnowledgeBaseConfiguration, transport: Transport) {
        self.configuration = configuration
        self.transport = transport
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    public func fetchKnowledgeBases() async throws -> [DifyKnowledgeBase] {
        var components = URLComponents(
            url: try endpoint(appending: ["datasets"]),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "limit", value: "100")
        ]
        guard let url = components?.url else {
            throw DifyKnowledgeBaseClientError.invalidBaseURL
        }
        var request = try authorizedRequest(url: url)
        request.httpMethod = "GET"
        let response = try await perform(request)
        do {
            let knowledgeBases = try decoder.decode(DatasetListResponse.self, from: response.data).data
            guard knowledgeBases.allSatisfy({
                Self.isSafeID($0.id) && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                throw DifyKnowledgeBaseClientError.invalidResponse
            }
            return knowledgeBases
        } catch {
            if let error = error as? DifyKnowledgeBaseClientError { throw error }
            throw DifyKnowledgeBaseClientError.invalidResponse
        }
    }

    public func retrieve(
        query: String,
        from knowledgeBaseID: String
    ) async throws -> DifyKnowledgeRetrievalResult {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw DifyKnowledgeBaseClientError.emptyQuery
        }
        guard normalizedQuery.count <= Self.maximumQueryLength else {
            throw DifyKnowledgeBaseClientError.queryTooLong(maximum: Self.maximumQueryLength)
        }
        guard Self.isSafeID(knowledgeBaseID) else {
            throw DifyKnowledgeBaseClientError.invalidKnowledgeBaseID
        }

        let url = try endpoint(appending: ["datasets", knowledgeBaseID, "retrieve"])
        var request = try authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try encoder.encode(RetrieveRequest(query: normalizedQuery))
        } catch {
            throw DifyKnowledgeBaseClientError.invalidResponse
        }

        let response = try await perform(request)
        do {
            let decoded = try decoder.decode(RetrieveResponse.self, from: response.data)
            return DifyKnowledgeRetrievalResult(
                query: decoded.query?.content ?? normalizedQuery,
                records: decoded.records
            )
        } catch {
            throw DifyKnowledgeBaseClientError.invalidResponse
        }
    }

    private func endpoint(appending pathComponents: [String]) throws -> URL {
        try validateConfiguration()
        let trimmed = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              var url = components.url
        else {
            throw DifyKnowledgeBaseClientError.invalidBaseURL
        }
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        return url
    }

    private func validateConfiguration() throws {
        guard configuration.enabled else {
            throw DifyKnowledgeBaseClientError.disabled
        }
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw DifyKnowledgeBaseClientError.emptyAPIKey
        }
        guard Self.isSafeAPIKey(apiKey) else {
            throw DifyKnowledgeBaseClientError.invalidAPIKey
        }
    }

    private func authorizedRequest(url: URL) throws -> URLRequest {
        let apiKey = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw DifyKnowledgeBaseClientError.emptyAPIKey
        }
        guard Self.isSafeAPIKey(apiKey) else {
            throw DifyKnowledgeBaseClientError.invalidAPIKey
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> DifyHTTPResponse {
        let response: DifyHTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut { throw DifyKnowledgeBaseClientError.timeout }
            throw DifyKnowledgeBaseClientError.transport(error.localizedDescription)
        } catch {
            throw DifyKnowledgeBaseClientError.transport(error.localizedDescription)
        }

        guard (200..<300).contains(response.statusCode) else {
            if let apiError = try? decoder.decode(DifyAPIError.self, from: response.data),
               !apiError.code.isEmpty,
               !apiError.message.isEmpty {
                throw DifyKnowledgeBaseClientError.api(
                    statusCode: response.statusCode,
                    code: String(apiError.code.prefix(200)),
                    message: String(apiError.message.prefix(2_000))
                )
            }
            throw DifyKnowledgeBaseClientError.httpStatus(response.statusCode)
        }
        return response
    }

    private static func isSafeID(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != "..", value.count <= 200 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isSafeAPIKey(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value == 0x0A || $0.value == 0x0D }
    }
}

private struct DatasetListResponse: Decodable {
    var data: [DifyKnowledgeBase]
}

private struct RetrieveRequest: Encodable {
    var query: String
    var retrievalModel = RetrievalModel()

    private enum CodingKeys: String, CodingKey {
        case query
        case retrievalModel = "retrieval_model"
    }
}

private struct RetrievalModel: Encodable {
    var searchMethod = "semantic_search"
    var rerankingEnable = false
    var topK = 5
    var scoreThresholdEnabled = false

    private enum CodingKeys: String, CodingKey {
        case searchMethod = "search_method"
        case rerankingEnable = "reranking_enable"
        case topK = "top_k"
        case scoreThresholdEnabled = "score_threshold_enabled"
    }
}

private struct RetrieveResponse: Decodable {
    var query: RetrieveQuery?
    var records: [DifyKnowledgeRetrievalRecord]
}

private struct RetrieveQuery: Decodable {
    var content: String
}

private struct DifyAPIError: Decodable {
    var code: String
    var message: String
}
