import Foundation

public struct DifyKnowledgeBaseConfiguration: Codable, Equatable, Sendable {
    public var baseURL: String
    public var apiKey: String
    public var enabled: Bool
    public var knowledgeBases: [DifyKnowledgeBase]
    public var selectedKnowledgeBaseIDs: [String]

    public init(
        baseURL: String = "",
        apiKey: String = "",
        enabled: Bool = false,
        knowledgeBases: [DifyKnowledgeBase] = [],
        selectedKnowledgeBaseIDs: [String] = []
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.enabled = enabled
        self.knowledgeBases = knowledgeBases
        self.selectedKnowledgeBaseIDs = selectedKnowledgeBaseIDs
    }

    public var selectedKnowledgeBases: [DifyKnowledgeBase] {
        var byID: [String: DifyKnowledgeBase] = [:]
        for knowledgeBase in knowledgeBases where byID[knowledgeBase.id] == nil {
            byID[knowledgeBase.id] = knowledgeBase
        }
        return selectedKnowledgeBaseIDs.compactMap { byID[$0] }
    }
}

public struct DifyKnowledgeBase: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct DifyKnowledgeRetrievalResult: Equatable, Sendable {
    public var query: String
    public var records: [DifyKnowledgeRetrievalRecord]

    public init(query: String, records: [DifyKnowledgeRetrievalRecord]) {
        self.query = query
        self.records = records
    }
}

public struct DifyKnowledgeRetrievalRecord: Codable, Equatable, Sendable {
    public var segment: DifyKnowledgeSegment
    public var score: Double?

    public init(segment: DifyKnowledgeSegment, score: Double? = nil) {
        self.segment = segment
        self.score = score
    }
}

public struct DifyKnowledgeSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var documentID: String?
    public var content: String
    public var answer: String?
    public var document: DifyKnowledgeDocument?

    public init(
        id: String,
        documentID: String? = nil,
        content: String,
        answer: String? = nil,
        document: DifyKnowledgeDocument? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.content = content
        self.answer = answer
        self.document = document
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case documentID = "document_id"
        case content
        case answer
        case document
    }
}

public struct DifyKnowledgeDocument: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}
