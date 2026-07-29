import AItingjiCore
import Foundation
import Testing

@Test
func difyConfigurationPreservesKnowledgeBasesAndSelectedOrder() throws {
    let configuration = DifyKnowledgeBaseConfiguration(
        baseURL: "https://dify.example/v1",
        apiKey: "dataset-secret",
        enabled: true,
        knowledgeBases: [
            DifyKnowledgeBase(id: "kb-1", name: "产品库"),
            DifyKnowledgeBase(id: "kb-2", name: "项目库", description: "项目资料")
        ],
        selectedKnowledgeBaseIDs: ["kb-2", "missing", "kb-1"]
    )

    let decoded = try JSONDecoder().decode(
        DifyKnowledgeBaseConfiguration.self,
        from: JSONEncoder().encode(configuration)
    )

    #expect(decoded == configuration)
    #expect(decoded.selectedKnowledgeBases.map(\.id) == ["kb-2", "kb-1"])
}

@Test
func difyClientFetchesFirstHundredKnowledgeBasesWithBearerAuthorization() async throws {
    let transport = RecordingDifyTransport(responses: [
        DifyHTTPResponse(
            data: Data(#"{"data":[{"id":"kb-1","name":"产品知识库","description":"产品资料","extra":"ignored"},{"id":"kb-2","name":"项目知识库","description":null}],"page":1,"limit":100,"total":2}"#.utf8),
            statusCode: 200
        )
    ])
    let client = makeDifyClient(transport: transport)

    let knowledgeBases = try await client.fetchKnowledgeBases()
    let request = try #require(await transport.requests().first)

    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "https://dify.example/v1/datasets?page=1&limit=100")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dataset-secret")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(knowledgeBases == [
        DifyKnowledgeBase(id: "kb-1", name: "产品知识库", description: "产品资料"),
        DifyKnowledgeBase(id: "kb-2", name: "项目知识库")
    ])
}

@Test
func difyClientRetrievesKnowledgeAndParsesEvidenceFields() async throws {
    let transport = RecordingDifyTransport(responses: [
        DifyHTTPResponse(
            data: Data(#"{"query":{"content":"项目风险"},"records":[{"segment":{"id":"seg-1","document_id":"doc-1","content":"交付期为九月底。","answer":null,"document":{"id":"doc-1","name":"项目计划"}},"score":0.91}]}"#.utf8),
            statusCode: 200
        )
    ])
    let client = makeDifyClient(transport: transport)

    let result = try await client.retrieve(query: "  项目风险  ", from: "kb-1")
    let request = try #require(await transport.requests().first)
    let body = try #require(request.httpBody)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let retrievalModel = try #require(object["retrieval_model"] as? [String: Any])

    #expect(request.httpMethod == "POST")
    #expect(request.url?.absoluteString == "https://dify.example/v1/datasets/kb-1/retrieve")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dataset-secret")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(object["query"] as? String == "项目风险")
    #expect(retrievalModel["search_method"] as? String == "semantic_search")
    #expect(retrievalModel["top_k"] as? Int == 5)
    #expect(result.query == "项目风险")
    #expect(result.records.first?.segment.documentID == "doc-1")
    #expect(result.records.first?.segment.document?.name == "项目计划")
    #expect(result.records.first?.segment.content == "交付期为九月底。")
    #expect(result.records.first?.score == 0.91)
}

@Test
func difyClientRejectsEmptyAndOverlongQueriesBeforeTransport() async throws {
    let transport = RecordingDifyTransport(responses: [])
    let client = makeDifyClient(transport: transport)

    await #expect(throws: DifyKnowledgeBaseClientError.emptyQuery) {
        try await client.retrieve(query: " \n ", from: "kb-1")
    }
    await #expect(throws: DifyKnowledgeBaseClientError.queryTooLong(maximum: 250)) {
        try await client.retrieve(query: String(repeating: "知", count: 251), from: "kb-1")
    }
    await #expect(throws: DifyKnowledgeBaseClientError.invalidKnowledgeBaseID) {
        try await client.retrieve(query: "风险", from: "..")
    }
    #expect(await transport.requests().isEmpty)
}

@Test
func difyClientAcceptsExactlyTwoHundredFiftyCharacters() async throws {
    let query = String(repeating: "知", count: 250)
    let transport = RecordingDifyTransport(responses: [
        DifyHTTPResponse(
            data: Data(#"{"query":{"content":"ok"},"records":[]}"#.utf8),
            statusCode: 200
        )
    ])
    let client = makeDifyClient(transport: transport)

    _ = try await client.retrieve(query: query, from: "kb-1")

    #expect(await transport.requests().count == 1)
}

@Test
func difyClientMapsConfigurationTransportAPIAndDecodeFailuresToStableErrors() async throws {
    let disabled = DifyKnowledgeBaseClient(
        configuration: DifyKnowledgeBaseConfiguration(
            baseURL: "https://dify.example/v1",
            apiKey: "dataset-secret",
            enabled: false
        ),
        transport: RecordingDifyTransport(responses: [])
    )
    await #expect(throws: DifyKnowledgeBaseClientError.disabled) {
        try await disabled.fetchKnowledgeBases()
    }

    let invalidURL = DifyKnowledgeBaseClient(
        configuration: DifyKnowledgeBaseConfiguration(
            baseURL: "not-a-url",
            apiKey: "dataset-secret",
            enabled: true
        ),
        transport: RecordingDifyTransport(responses: [])
    )
    await #expect(throws: DifyKnowledgeBaseClientError.invalidBaseURL) {
        try await invalidURL.fetchKnowledgeBases()
    }

    let emptyKey = DifyKnowledgeBaseClient(
        configuration: DifyKnowledgeBaseConfiguration(
            baseURL: "https://dify.example/v1",
            apiKey: "  ",
            enabled: true
        ),
        transport: RecordingDifyTransport(responses: [])
    )
    await #expect(throws: DifyKnowledgeBaseClientError.emptyAPIKey) {
        try await emptyKey.fetchKnowledgeBases()
    }

    let invalidKey = DifyKnowledgeBaseClient(
        configuration: DifyKnowledgeBaseConfiguration(
            baseURL: "https://dify.example/v1",
            apiKey: "secret\r\nInjected: value",
            enabled: true
        ),
        transport: RecordingDifyTransport(responses: [])
    )
    await #expect(throws: DifyKnowledgeBaseClientError.invalidAPIKey) {
        try await invalidKey.fetchKnowledgeBases()
    }

    let timeout = makeDifyClient(transport: RecordingDifyTransport(error: URLError(.timedOut)))
    await #expect(throws: DifyKnowledgeBaseClientError.timeout) {
        try await timeout.fetchKnowledgeBases()
    }

    let unauthorized = makeDifyClient(transport: RecordingDifyTransport(responses: [
        DifyHTTPResponse(
            data: Data(#"{"code":"unauthorized","message":"API key is invalid","status":401}"#.utf8),
            statusCode: 401
        )
    ]))
    await #expect(throws: DifyKnowledgeBaseClientError.api(
        statusCode: 401,
        code: "unauthorized",
        message: "API key is invalid"
    )) {
        try await unauthorized.fetchKnowledgeBases()
    }

    let malformed = makeDifyClient(transport: RecordingDifyTransport(responses: [
        DifyHTTPResponse(data: Data(#"{"data":"wrong"}"#.utf8), statusCode: 200)
    ]))
    await #expect(throws: DifyKnowledgeBaseClientError.invalidResponse) {
        try await malformed.fetchKnowledgeBases()
    }
}

private func makeDifyClient(
    transport: RecordingDifyTransport
) -> DifyKnowledgeBaseClient<RecordingDifyTransport> {
    DifyKnowledgeBaseClient(
        configuration: DifyKnowledgeBaseConfiguration(
            baseURL: "https://dify.example/v1/",
            apiKey: " dataset-secret ",
            enabled: true
        ),
        transport: transport
    )
}

private actor RecordingDifyTransport: DifyHTTPTransport {
    private var queuedResponses: [DifyHTTPResponse]
    private var recordedRequests: [URLRequest] = []
    private let error: (any Error & Sendable)?

    init(responses: [DifyHTTPResponse]) {
        queuedResponses = responses
        error = nil
    }

    init(error: any Error & Sendable) {
        queuedResponses = []
        self.error = error
    }

    func send(_ request: URLRequest) async throws -> DifyHTTPResponse {
        recordedRequests.append(request)
        if let error { throw error }
        guard !queuedResponses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return queuedResponses.removeFirst()
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}
