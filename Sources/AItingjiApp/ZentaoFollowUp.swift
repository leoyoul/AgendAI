import AItingjiCore
import Foundation

enum FollowUpSource: String, Codable, Sendable {
    case action
    case unresolved
}

enum FollowUpMatchStatus: String, Codable, Sendable {
    case matched
    case partial
    case pending
    case failed
    case handedOff

    var displayName: String {
        switch self {
        case .matched: "已匹配"
        case .partial: "部分匹配"
        case .pending: "待确认"
        case .failed: "匹配失败"
        case .handedOff: "已交接"
        }
    }
}

struct ZentaoFollowUpTodo: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var meetingID: Meeting.ID
    var title: String
    var projectName: String
    var executionName: String
    var ownerName: String
    var plannedStart: String
    var plannedEnd: String
    var source: FollowUpSource
    var status: FollowUpMatchStatus
    var projectID: String?
    var executionID: String?
    var ownerID: String?
    var taskID: String?
    var errorMessage: String?
    var updatedAt: Date

    init(
        id: String,
        meetingID: Meeting.ID,
        title: String,
        projectName: String,
        executionName: String,
        ownerName: String,
        plannedStart: String,
        plannedEnd: String,
        source: FollowUpSource,
        status: FollowUpMatchStatus,
        projectID: String? = nil,
        executionID: String? = nil,
        ownerID: String? = nil,
        taskID: String? = nil,
        errorMessage: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.title = title
        self.projectName = projectName
        self.executionName = executionName
        self.ownerName = ownerName
        self.plannedStart = plannedStart
        self.plannedEnd = plannedEnd
        self.source = source
        self.status = status
        self.projectID = projectID
        self.executionID = executionID
        self.ownerID = ownerID
        self.taskID = taskID
        self.errorMessage = errorMessage
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, meetingID, title, projectName, executionName, ownerName
        case plannedStart, plannedEnd, source, status
        case projectID, executionID, ownerID, taskID, errorMessage, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        meetingID = try values.decode(String.self, forKey: .meetingID)
        title = try values.decode(String.self, forKey: .title)
        projectName = try values.decode(String.self, forKey: .projectName)
        executionName = try values.decode(String.self, forKey: .executionName)
        ownerName = try values.decode(String.self, forKey: .ownerName)
        plannedStart = try values.decode(String.self, forKey: .plannedStart)
        plannedEnd = try values.decode(String.self, forKey: .plannedEnd)
        source = try values.decode(FollowUpSource.self, forKey: .source)
        status = try values.decode(FollowUpMatchStatus.self, forKey: .status)
        projectID = try values.decodeIfPresent(String.self, forKey: .projectID)
        executionID = try values.decodeIfPresent(String.self, forKey: .executionID)
        ownerID = try values.decodeIfPresent(String.self, forKey: .ownerID)
        taskID = try values.decodeIfPresent(String.self, forKey: .taskID)
        errorMessage = try values.decodeIfPresent(String.self, forKey: .errorMessage)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

struct ZentaoFollowUpMatchResult: Codable, Sendable {
    var meetingID: Meeting.ID
    var generatedAt: Date
    var todos: [ZentaoFollowUpTodo]
}

enum ZentaoMCPError: LocalizedError, Sendable {
    case unavailable
    case invalidResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "未配置可用的禅道 MCP。"
        case .invalidResponse: "禅道 MCP 返回的数据格式无效。"
        case .message(let value): value
        }
    }
}

struct ZentaoMCPClient: Sendable {
    typealias ResponseGenerator = @Sendable (String, URL, URL?) async throws -> String

    static let defaultTimeout: Duration = .seconds(600)

    private let responseGenerator: ResponseGenerator

    init(responseGenerator: @escaping ResponseGenerator = { prompt, workingDirectory, mcpConfigURL in
        try await ClaudeCodeClient().run(
            prompt: prompt,
            workingDirectory: workingDirectory,
            mcpConfigURL: mcpConfigURL,
            timeout: Self.defaultTimeout
        )
    }) {
        self.responseGenerator = responseGenerator
    }

    func match(
        meeting: Meeting,
        minutes: MeetingMinutesDocument,
        source: ModelSource,
        runtime: PiAgentRuntimeConfiguration,
        mcpConfigURL: URL? = nil
    ) async throws -> ZentaoFollowUpMatchResult {
        let prompt = Self.matchPrompt(meeting: meeting, minutes: minutes)
        let raw = try await responseGenerator(prompt, runtime.workingDirectoryURL, mcpConfigURL)
        guard let data = Self.extractJSON(raw).data(using: .utf8) else { throw ZentaoMCPError.invalidResponse }
        return try Self.decoder().decode(ZentaoFollowUpMatchResult.self, from: data)
    }

    func create(
        todo: ZentaoFollowUpTodo,
        meeting: Meeting,
        source: ModelSource,
        runtime: PiAgentRuntimeConfiguration,
        mcpConfigURL: URL? = nil
    ) async throws -> ZentaoFollowUpTodo {
        let request = """
        你是禅道 MCP 适配器。仅为不存在的任务创建禅道任务；已有任务必须原样返回并标记 status=handedOff。
        只输出 JSON 对象，字段必须与输入一致，并补充 taskID/status/errorMessage。
        输入会议：\(meeting.title)
        输入任务：\(String(data: try JSONEncoder().encode(todo), encoding: .utf8) ?? "{}")
        """
        let raw = try await responseGenerator(request, runtime.workingDirectoryURL, mcpConfigURL)
        guard let data = Self.extractJSON(raw).data(using: .utf8),
              let result = try? Self.decoder().decode(ZentaoFollowUpTodo.self, from: data) else {
            throw ZentaoMCPError.invalidResponse
        }
        return result
    }

    private static func matchPrompt(meeting: Meeting, minutes: MeetingMinutesDocument) -> String {
        let payload = (try? JSONEncoder().encode(minutes)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        你是禅道 MCP 适配器。根据会议上下文查询禅道项目、执行、人员和已有任务，并把会议纪要中的 actions 与 risks 转成会后待办。
        项目用会议标题、摘要、结论和待办上下文匹配；任务名称对应执行名称；负责人必须是禅道人员。
        计划开始/结束时间优先使用会议纪要或禅道执行数据，缺失写“待确认”，不要推算。
        只输出一个 JSON 对象：{\"meetingID\":\"...\",\"generatedAt\":\"ISO8601\",\"todos\":[...] }。
        todos 每项必须包含 id, meetingID, title, projectName, executionName, ownerName, plannedStart, plannedEnd, source, status；
        已存在实体填充对应 ID，状态使用 matched/partial/pending；查询失败使用 failed 并写 errorMessage。
        meetingID=\(meeting.id)；会议标题=\(meeting.title)；会议纪要 JSON=\(payload)
        """
    }

    private static func extractJSON(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}") else { return trimmed }
        return String(trimmed[first...last])
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            if let date = ISO8601DateFormatter().date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "不是有效的 ISO8601 日期：\(value)"
            )
        }
        return decoder
    }
}
