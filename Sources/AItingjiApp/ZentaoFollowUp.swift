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
    var normalizationWarnings: [String]

    init(meetingID: Meeting.ID, generatedAt: Date, todos: [ZentaoFollowUpTodo], normalizationWarnings: [String] = []) {
        self.meetingID = meetingID
        self.generatedAt = generatedAt
        self.todos = todos
        self.normalizationWarnings = normalizationWarnings
    }

    private enum CodingKeys: String, CodingKey {
        case meetingID, generatedAt, todos, normalizationWarnings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        meetingID = try values.decode(String.self, forKey: .meetingID)
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        todos = try values.decode([ZentaoFollowUpTodo].self, forKey: .todos)
        normalizationWarnings = try values.decodeIfPresent([String].self, forKey: .normalizationWarnings) ?? []
    }
}

enum ZentaoMCPError: LocalizedError, Sendable {
    case unavailable
    case permissionDenied([String])
    case responseContract(path: String?, expected: String?, actual: String?, message: String, retryPerformed: Bool)
    case meetingMismatch(expected: String, actual: String)
    case duplicateTodoID(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "未配置可用的禅道 MCP。"
        case .permissionDenied(let tools):
            "禅道 MCP 工具未授权：\(tools.joined(separator: ", "))"
        case .responseContract(let path, let expected, let actual, let message, _):
            if let path, let expected, let actual {
                "返回格式错误：\(path) 应为\(expected)，实际为\(actual)。\(message)"
            } else {
                "禅道 MCP 返回的数据格式无效。\(message)"
            }
        case .meetingMismatch(let expected, let actual):
            "返回结果的会议 ID 不一致：期望 \(expected)，实际 \(actual)。"
        case .duplicateTodoID(let id):
            "返回结果包含重复的待办 ID：\(id)。"
        case .message(let value):
            value
        }
    }

    var isRetryableContractFailure: Bool {
        if case .responseContract = self { return true }
        return false
    }

    func withRetryPerformed() -> ZentaoMCPError {
        guard case .responseContract(let path, let expected, let actual, let message, _) = self else { return self }
        return .responseContract(path: path, expected: expected, actual: actual, message: message, retryPerformed: true)
    }

    var diagnostic: ClaudeCodeDiagnostic {
        switch self {
        case .permissionDenied(let tools):
            return ClaudeCodeDiagnostic(
                phase: "permission",
                summary: errorDescription ?? "禅道 MCP 工具未授权。",
                mcpName: "zentao",
                deniedTools: tools
            )
        case .responseContract(let path, let expected, let actual, _, let retried):
            return ClaudeCodeDiagnostic(
                phase: "parse.schema",
                summary: errorDescription ?? "禅道 MCP 返回的数据格式无效。",
                mcpName: "zentao",
                responsePath: path,
                expectedType: expected,
                actualType: actual,
                structuredOutputRetryPerformed: retried
            )
        case .meetingMismatch:
            return ClaudeCodeDiagnostic(phase: "parse.validation", summary: errorDescription ?? "会议 ID 不一致。", mcpName: "zentao")
        case .duplicateTodoID:
            return ClaudeCodeDiagnostic(phase: "parse.validation", summary: errorDescription ?? "待办 ID 重复。", mcpName: "zentao")
        case .unavailable, .message:
            return ClaudeCodeDiagnostic(phase: "mcp", summary: errorDescription ?? "禅道 MCP 不可用。", mcpName: "zentao")
        }
    }
}

struct ZentaoMCPProbeResult: Sendable, Equatable {
    var message: String
    var availableTools: [String]
}

struct ZentaoMCPClient: Sendable {
    typealias ResponseGenerator = @Sendable (String, URL, URL?) async throws -> String
    typealias ConfiguredResponseGenerator = @Sendable (String, URL, URL?, ClaudeCodeInvocationOptions) async throws -> String

    static let defaultTimeout: Duration = .seconds(600)
    static let readOnlyToolNames = [
        "mcp__zentao__get_users",
        "mcp__zentao__get_projects",
        "mcp__zentao__get_projects_projectID_executions",
        "mcp__zentao__get_executions",
        "mcp__zentao__get_executions_executionID",
        "mcp__zentao__get_executions_executionID_tasks",
        "mcp__zentao__get_tasks_taskID"
    ]
    static let postTasksToolName = "mcp__zentao__post_tasks"

    private static let todoFields = "id, meetingID, title, projectName, executionName, ownerName, plannedStart, plannedEnd, source, status"

    private let responseGenerator: ResponseGenerator?
    private let configuredResponseGenerator: ConfiguredResponseGenerator?

    init() {
        self.responseGenerator = nil
        self.configuredResponseGenerator = nil
    }

    init(responseGenerator: @escaping ResponseGenerator) {
        self.responseGenerator = responseGenerator
        self.configuredResponseGenerator = nil
    }

    init(configuredResponseGenerator: @escaping ConfiguredResponseGenerator) {
        self.responseGenerator = nil
        self.configuredResponseGenerator = configuredResponseGenerator
    }

    func match(
        meeting: Meeting,
        minutes: MeetingMinutesDocument,
        source: ModelSource,
        runtime: PiAgentRuntimeConfiguration,
        mcpConfigURL: URL? = nil
    ) async throws -> ZentaoFollowUpMatchResult {
        let prompt = Self.matchPrompt(meeting: meeting, minutes: minutes)
        let options = Self.invocationOptions(schema: Self.matchJSONSchema, includeWriteTools: false)
        let raw = try await request(prompt: prompt, runtime: runtime, mcpConfigURL: mcpConfigURL, options: options)
        do {
            return try Self.decodeMatch(raw, expectedMeetingID: meeting.id)
        } catch let error as ZentaoMCPError where error.isRetryableContractFailure {
            let retryPrompt = prompt + Self.contractRepairPrompt(error)
            do {
                let retryRaw = try await request(prompt: retryPrompt, runtime: runtime, mcpConfigURL: mcpConfigURL, options: options)
                var result = try Self.decodeMatch(retryRaw, expectedMeetingID: meeting.id)
                result.normalizationWarnings.insert("结构化输出校验失败后已执行一次修复重试。", at: 0)
                return result
            } catch let retryError as ZentaoMCPError {
                throw retryError.withRetryPerformed()
            }
        }
    }

    func create(
        todo: ZentaoFollowUpTodo,
        meeting: Meeting,
        source: ModelSource,
        runtime: PiAgentRuntimeConfiguration,
        mcpConfigURL: URL? = nil
    ) async throws -> ZentaoFollowUpTodo {
        let input = String(data: try JSONEncoder().encode(todo), encoding: .utf8) ?? "{}"
        let requestPrompt = """
        你是禅道 MCP 适配器。仅为不存在的任务创建禅道任务；已有任务不得重复创建，直接返回原任务并标记 status=handedOff。
        先使用允许的只读工具确认项目、执行、负责人和已有任务，再仅在必要时调用 post_tasks。
        只输出符合 JSON Schema 的 JSON 对象，不输出解释、Markdown 或代码块。
        返回对象必须保留输入字段，补充 taskID、status=handedOff 和 errorMessage=null。
        输入会议 ID：\(meeting.id)
        输入会议标题：\(meeting.title)
        输入任务 JSON：\(input)
        """
        let options = Self.invocationOptions(schema: Self.todoJSONSchema, includeWriteTools: true)
        let raw = try await request(prompt: requestPrompt, runtime: runtime, mcpConfigURL: mcpConfigURL, options: options)
        let (result, _) = try Self.decodeTodo(raw, expectedMeetingID: meeting.id, path: "todo")
        guard result.id == todo.id else {
            throw ZentaoMCPError.responseContract(path: "todo.id", expected: "与输入任务 ID 一致", actual: result.id, message: "", retryPerformed: false)
        }
        guard result.status == .handedOff else {
            throw ZentaoMCPError.responseContract(path: "todo.status", expected: "handedOff", actual: result.status.rawValue, message: "交接结果必须明确标记为已交接。", retryPerformed: false)
        }
        guard let taskID = result.taskID, !taskID.isEmpty else {
            throw ZentaoMCPError.responseContract(path: "todo.taskID", expected: "非空字符串", actual: "missing", message: "交接成功必须返回 taskID。", retryPerformed: false)
        }
        _ = taskID
        return result
    }

    func probe(
        runtime: PiAgentRuntimeConfiguration,
        mcpConfigURL: URL? = nil
    ) async throws -> ZentaoMCPProbeResult {
        let prompt = """
        你是禅道 MCP 连通性测试器。只调用一次 mcp__zentao__get_projects 读取项目列表，验证禅道 MCP 可用性。
        不得调用任何写入、删除、修改、文件或 Shell 工具。
        只输出符合 JSON Schema 的 JSON 对象，不输出解释、Markdown 或代码块。
        """
        let options = Self.invocationOptions(schema: Self.probeJSONSchema, includeWriteTools: false)
        let raw = try await request(prompt: prompt, runtime: runtime, mcpConfigURL: mcpConfigURL, options: options)
        try Self.throwIfPermissionDenied(raw)
        let object = try Self.decodeJSONObject(raw)
        guard let ok = object["ok"] as? Bool else {
            throw Self.contract(path: "ok", expected: "布尔值", actual: Self.actualType(object["ok"]), message: "")
        }
        guard ok else {
            let message = (object["message"] as? String) ?? "禅道 MCP 测试失败。"
            throw ZentaoMCPError.message(message)
        }
        let message = (object["message"] as? String) ?? "禅道 MCP 连接成功。"
        let tools = (object["availableTools"] as? [String]) ?? []
        return ZentaoMCPProbeResult(message: message, availableTools: tools)
    }

    private func request(
        prompt: String,
        runtime: PiAgentRuntimeConfiguration,
        mcpConfigURL: URL?,
        options: ClaudeCodeInvocationOptions
    ) async throws -> String {
        if let configuredResponseGenerator {
            return try await configuredResponseGenerator(prompt, runtime.workingDirectoryURL, mcpConfigURL, options)
        }
        if let responseGenerator {
            return try await responseGenerator(prompt, runtime.workingDirectoryURL, mcpConfigURL)
        }
        return try await ClaudeCodeClient().run(
            prompt: prompt,
            workingDirectory: runtime.workingDirectoryURL,
            mcpConfigURL: mcpConfigURL,
            timeout: Self.defaultTimeout,
            options: options
        )
    }

    private static func invocationOptions(schema: String, includeWriteTools: Bool) -> ClaudeCodeInvocationOptions {
        var tools = readOnlyToolNames
        if includeWriteTools { tools.append(postTasksToolName) }
        return ClaudeCodeInvocationOptions(
            allowedTools: tools,
            builtInTools: "",
            permissionPrompts: "none",
            jsonSchema: schema
        )
    }

    private static func matchPrompt(meeting: Meeting, minutes: MeetingMinutesDocument) -> String {
        let payload = (try? JSONEncoder().encode(minutes)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        你是禅道 MCP 适配器。根据会议上下文查询禅道项目、执行、人员和已有任务，并把会议纪要中的 actions 与 risks 转成会后待办。
        项目用会议标题、摘要、结论和待办上下文匹配；任务名称对应执行名称；负责人必须是禅道人员。
        计划开始/结束时间优先使用会议纪要或禅道执行数据，缺失写“待确认”，不要推算。
        必须先调用需要的只读禅道 MCP 工具；任何工具未授权或调用失败时，不得编造项目、执行、人员或任务数据。
        只输出一个符合 JSON Schema 的 JSON 对象，不输出解释、Markdown 或代码块。
        todos 每项必须包含 \(todoFields)；已存在实体填充对应 ID，状态使用 matched/partial/pending；查询失败使用 failed 并写 errorMessage。
        meetingID=\(meeting.id)；会议标题=\(meeting.title)；会议纪要 JSON=\(payload)
        """
    }

    private static func contractRepairPrompt(_ error: ZentaoMCPError) -> String {
        """

        上一次输出未通过结构化契约：\(error.localizedDescription)
        请仅修复该契约问题并重新输出完整 JSON；不要输出解释、Markdown 或代码块，也不要伪造任何未查询到的禅道数据。
        """
    }

    private static let matchJSONSchema = """
    {"$id":"ai-tingji.zentao.follow-up.match.v1","type":"object","additionalProperties":false,"required":["meetingID","generatedAt","todos"],"properties":{"meetingID":{"type":"string"},"generatedAt":{"type":"string"},"todos":{"type":"array","items":{"$ref":"#/$defs/todo"}}},"$defs":{"todo":{"type":"object","additionalProperties":false,"required":["id","meetingID","title","projectName","executionName","ownerName","plannedStart","plannedEnd","source","status"],"properties":{"id":{"type":"string"},"meetingID":{"type":"string"},"title":{"type":"string","minLength":1},"projectName":{"type":"string"},"executionName":{"type":"string"},"ownerName":{"type":"string"},"plannedStart":{"type":"string"},"plannedEnd":{"type":"string"},"source":{"enum":["action","unresolved"]},"status":{"enum":["matched","partial","pending","failed","handedOff"]},"projectID":{"type":["string","null"]},"executionID":{"type":["string","null"]},"ownerID":{"type":["string","null"]},"taskID":{"type":["string","null"]},"errorMessage":{"type":["string","null"]},"updatedAt":{"type":["string","number","null"]}}}}
    """

    private static let todoJSONSchema = """
    {"$id":"ai-tingji.zentao.follow-up.todo.v1","type":"object","additionalProperties":false,"required":["id","meetingID","title","projectName","executionName","ownerName","plannedStart","plannedEnd","source","status","taskID","errorMessage"],"properties":{"id":{"type":"string"},"meetingID":{"type":"string"},"title":{"type":"string","minLength":1},"projectName":{"type":"string"},"executionName":{"type":"string"},"ownerName":{"type":"string"},"plannedStart":{"type":"string"},"plannedEnd":{"type":"string"},"source":{"enum":["action","unresolved"]},"status":{"const":"handedOff"},"projectID":{"type":["string","null"]},"executionID":{"type":["string","null"]},"ownerID":{"type":["string","null"]},"taskID":{"type":"string","minLength":1},"errorMessage":{"type":["string","null"]},"updatedAt":{"type":["string","number","null"]}}}
    """

    private static let probeJSONSchema = """
    {"type":"object","additionalProperties":false,"required":["ok","message"],"properties":{"ok":{"type":"boolean"},"message":{"type":"string"},"availableTools":{"type":"array","items":{"type":"string"}}}}
    """

    private static func decodeMatch(_ raw: String, expectedMeetingID: String) throws -> ZentaoFollowUpMatchResult {
        try throwIfPermissionDenied(raw)
        let object = try decodeJSONObject(raw)
        var topLevelWarnings: [String] = []
        let meetingID = try requiredString(object, keys: ["meetingID", "meetingId", "meeting_id"], path: "meetingID", warnings: &topLevelWarnings)
        guard meetingID == expectedMeetingID else {
            throw ZentaoMCPError.meetingMismatch(expected: expectedMeetingID, actual: meetingID)
        }
        let generatedAt = try flexibleDate(objectValue(object, keys: ["generatedAt", "generated_at"]).value, path: "generatedAt")
        guard let todosValue = objectValue(object, keys: ["todos"]).value else {
            throw contract(path: "todos", expected: "数组", actual: "missing", message: "")
        }
        guard let todoObjects = todosValue as? [Any] else {
            throw contract(path: "todos", expected: "数组", actual: actualType(todosValue), message: "")
        }

        var warnings = topLevelWarnings
        var todos: [ZentaoFollowUpTodo] = []
        var ids = Set<String>()
        for (index, value) in todoObjects.enumerated() {
            guard let todoObject = value as? [String: Any] else {
                throw contract(path: "todos[\(index)]", expected: "对象", actual: actualType(value), message: "")
            }
            let (todo, todoWarnings) = try decodeTodoObject(todoObject, expectedMeetingID: expectedMeetingID, path: "todos[\(index)]")
            if !ids.insert(todo.id).inserted { throw ZentaoMCPError.duplicateTodoID(todo.id) }
            warnings.append(contentsOf: todoWarnings)
            todos.append(todo)
        }
        return ZentaoFollowUpMatchResult(meetingID: meetingID, generatedAt: generatedAt, todos: todos, normalizationWarnings: warnings)
    }

    private static func decodeTodo(_ raw: String, expectedMeetingID: String, path: String) throws -> (ZentaoFollowUpTodo, [String]) {
        try throwIfPermissionDenied(raw)
        let object = try decodeJSONObject(raw)
        return try decodeTodoObject(object, expectedMeetingID: expectedMeetingID, path: path)
    }

    private static func decodeTodoObject(_ object: [String: Any], expectedMeetingID: String, path: String) throws -> (ZentaoFollowUpTodo, [String]) {
        var warnings: [String] = []
        let id = try requiredString(object, keys: ["id"], path: "\(path).id", warnings: &warnings)
        let meetingID = try requiredString(object, keys: ["meetingID", "meetingId", "meeting_id"], path: "\(path).meetingID", warnings: &warnings)
        guard meetingID == expectedMeetingID else {
            throw ZentaoMCPError.meetingMismatch(expected: expectedMeetingID, actual: meetingID)
        }
        let title = try requiredString(object, keys: ["title"], path: "\(path).title", warnings: &warnings).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw contract(path: "\(path).title", expected: "非空字符串", actual: "empty", message: "") }
        let projectName = try requiredString(object, keys: ["projectName", "project_name"], path: "\(path).projectName", fallbackOnNull: "待确认", warnings: &warnings)
        let executionName = try requiredString(object, keys: ["executionName", "execution_name"], path: "\(path).executionName", fallbackOnNull: "待确认", warnings: &warnings)
        let ownerName = try requiredString(object, keys: ["ownerName", "owner_name"], path: "\(path).ownerName", fallbackOnNull: "待确认", warnings: &warnings)
        let plannedStart = try requiredString(object, keys: ["plannedStart", "planned_start"], path: "\(path).plannedStart", fallbackOnNull: "待确认", warnings: &warnings)
        let plannedEnd = try requiredString(object, keys: ["plannedEnd", "planned_end"], path: "\(path).plannedEnd", fallbackOnNull: "待确认", warnings: &warnings)

        let rawSource = try requiredString(object, keys: ["source"], path: "\(path).source", warnings: &warnings)
        let source: FollowUpSource
        if let value = FollowUpSource(rawValue: rawSource) {
            source = value
        } else if rawSource.hasPrefix("action-") {
            source = .action
            warnings.append("\(path).source 已从 action 扩展值归一化为 action。")
        } else if rawSource.hasPrefix("unresolved-") {
            source = .unresolved
            warnings.append("\(path).source 已从 unresolved 扩展值归一化为 unresolved。")
        } else {
            throw contract(path: "\(path).source", expected: "action 或 unresolved", actual: rawSource, message: "")
        }

        let rawStatus = try requiredString(object, keys: ["status"], path: "\(path).status", warnings: &warnings)
        guard let status = FollowUpMatchStatus(rawValue: rawStatus) else {
            throw contract(path: "\(path).status", expected: "matched/partial/pending/failed/handedOff", actual: rawStatus, message: "")
        }
        let projectID = try optionalString(object, keys: ["projectID", "project_id"], path: "\(path).projectID", warnings: &warnings)
        let executionID = try optionalString(object, keys: ["executionID", "execution_id"], path: "\(path).executionID", warnings: &warnings)
        let ownerID = try optionalString(object, keys: ["ownerID", "owner_id"], path: "\(path).ownerID", warnings: &warnings)
        let taskID = try optionalString(object, keys: ["taskID", "task_id"], path: "\(path).taskID", warnings: &warnings)
        let errorMessage = try optionalString(object, keys: ["errorMessage", "error_message"], path: "\(path).errorMessage", warnings: &warnings)
        let updatedAt: Date
        if let value = objectValue(object, keys: ["updatedAt", "updated_at"]).value {
            updatedAt = try flexibleDate(value, path: "\(path).updatedAt")
        } else {
            updatedAt = Date()
        }

        if status == .matched && (projectID == nil || executionID == nil || ownerID == nil) {
            throw contract(path: "\(path).status", expected: "matched 且包含 projectID、executionID、ownerID", actual: "matched", message: "")
        }
        if status == .failed && (errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw contract(path: "\(path).errorMessage", expected: "failed 状态下的非空字符串", actual: "missing", message: "")
        }

        return (
            ZentaoFollowUpTodo(
                id: id,
                meetingID: meetingID,
                title: title,
                projectName: projectName,
                executionName: executionName,
                ownerName: ownerName,
                plannedStart: plannedStart,
                plannedEnd: plannedEnd,
                source: source,
                status: status,
                projectID: projectID,
                executionID: executionID,
                ownerID: ownerID,
                taskID: taskID,
                errorMessage: errorMessage,
                updatedAt: updatedAt
            ),
            warnings
        )
    }

    private static func decodeJSONObject(_ raw: String) throws -> [String: Any] {
        let parsedResponse = (try? ClaudeCodeClient.parseResponse(raw)) ?? raw
        let candidates = [parsedResponse, raw]
        for candidate in candidates {
            if let data = extractJSONObjectData(candidate),
               let object = try? JSONSerialization.jsonObject(with: data),
               let dictionary = object as? [String: Any] {
                return dictionary
            }
        }
        throw contract(path: nil, expected: "JSON 对象", actual: "非 JSON", message: "")
    }

    private static func extractJSONObjectData(_ value: String) -> Data? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           object is [String: Any] {
            return data
        }

        var start: String.Index?
        var depth = 0
        var inString = false
        var escaped = false
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}" && depth > 0 {
                depth -= 1
                if depth == 0, let objectStart = start {
                    let candidate = String(trimmed[objectStart...index])
                    if let data = candidate.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data),
                       object is [String: Any] {
                        return data
                    }
                    start = nil
                }
            }
            index = trimmed.index(after: index)
        }
        return nil
    }

    private static func throwIfPermissionDenied(_ value: String) throws {
        let lowercased = value.lowercased()
        let markers = ["requested permissions", "haven't granted", "permission denied", "not authorized", "未授权"]
        guard markers.contains(where: { lowercased.contains($0) }) else { return }
        let pattern = #"mcp__zentao__[A-Za-z0-9_]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        var names: [String] = []
        expression.enumerateMatches(in: value, range: range) { match, _, _ in
            guard let match, let matchRange = Range(match.range, in: value) else { return }
            let name = String(value[matchRange])
            if !names.contains(name) { names.append(name) }
        }
        if !names.isEmpty { throw ZentaoMCPError.permissionDenied(names) }
    }

    private static func objectValue(_ object: [String: Any], keys: [String]) -> (value: Any?, found: Bool) {
        for key in keys where object[key] != nil { return (object[key], true) }
        return (nil, false)
    }

    private static func requiredString(
        _ object: [String: Any],
        keys: [String],
        path: String,
        fallbackOnNull: String? = nil,
        warnings: inout [String]
    ) throws -> String {
        let value = objectValue(object, keys: keys)
        guard value.found, let raw = value.value else {
            throw contract(path: path, expected: "字符串", actual: "missing", message: "")
        }
        if raw is NSNull {
            if let fallbackOnNull {
                warnings.append("\(path) 的 null 已归一化为“\(fallbackOnNull)”。")
                return fallbackOnNull
            }
            throw contract(path: path, expected: "字符串", actual: "null", message: "")
        }
        if let string = raw as? String { return string }
        if isBoolean(raw) { throw contract(path: path, expected: "字符串", actual: "布尔值", message: "") }
        if let number = raw as? NSNumber {
            warnings.append("\(path) 已从数字归一化为字符串。")
            return number.stringValue
        }
        throw contract(path: path, expected: "字符串", actual: actualType(raw), message: "")
    }

    private static func optionalString(
        _ object: [String: Any],
        keys: [String],
        path: String,
        warnings: inout [String]
    ) throws -> String? {
        let value = objectValue(object, keys: keys)
        guard value.found, let raw = value.value else { return nil }
        if raw is NSNull { return nil }
        return try requiredString(object, keys: keys, path: path, warnings: &warnings)
    }

    private static func flexibleDate(_ raw: Any?, path: String) throws -> Date {
        guard let raw else { throw contract(path: path, expected: "ISO8601 日期或 Unix 时间戳", actual: "missing", message: "") }
        if raw is NSNull { throw contract(path: path, expected: "ISO8601 日期或 Unix 时间戳", actual: "null", message: "") }
        if isBoolean(raw) { throw contract(path: path, expected: "ISO8601 日期或 Unix 时间戳", actual: "布尔值", message: "") }
        if let number = raw as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue) }
        if let value = raw as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw contract(path: path, expected: "有效 ISO8601 日期", actual: value, message: "")
        }
        throw contract(path: path, expected: "ISO8601 日期或 Unix 时间戳", actual: actualType(raw), message: "")
    }

    private static func actualType(_ value: Any?) -> String {
        guard let value else { return "missing" }
        if value is NSNull { return "null" }
        if value is String { return "字符串" }
        if isBoolean(value) { return "布尔值" }
        if value is NSNumber { return "数字" }
        if value is [Any] { return "数组" }
        if value is [String: Any] { return "对象" }
        return String(describing: type(of: value))
    }

    private static func isBoolean(_ value: Any) -> Bool {
        if let number = value as? NSNumber {
            return String(cString: number.objCType) == "c"
        }
        return value is Bool
    }

    private static func contract(path: String?, expected: String?, actual: String?, message: String) -> ZentaoMCPError {
        .responseContract(path: path, expected: expected, actual: actual, message: message, retryPerformed: false)
    }
}
