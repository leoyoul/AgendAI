import Foundation

public struct MeetingAgentJobRequest: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var requestID: String
    public var meeting: MeetingAgentMeetingInput
    public var transcript: MeetingAgentTranscriptInput
    public var attachments: [MeetingAgentAttachmentInput]
    public var analysis: MeetingAgentAnalysisInput
    public var output: MeetingAgentOutputInput

    public init(
        schemaVersion: String = "1.0",
        requestID: String,
        meeting: MeetingAgentMeetingInput,
        transcript: MeetingAgentTranscriptInput,
        attachments: [MeetingAgentAttachmentInput] = [],
        analysis: MeetingAgentAnalysisInput,
        output: MeetingAgentOutputInput = MeetingAgentOutputInput()
    ) {
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.meeting = meeting
        self.transcript = transcript
        self.attachments = attachments
        self.analysis = analysis
        self.output = output
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case requestID = "request_id"
        case meeting
        case transcript
        case attachments
        case analysis
        case output
    }
}

public struct MeetingAgentMeetingInput: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var startedAt: String
    public var endedAt: String
    public var timezone: String
    public var captureSource: String
    public var participants: [MeetingAgentParticipantInput]

    public init(
        id: String,
        title: String,
        startedAt: String,
        endedAt: String,
        timezone: String,
        captureSource: String,
        participants: [MeetingAgentParticipantInput]
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timezone = timezone
        self.captureSource = captureSource
        self.participants = participants
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case timezone
        case captureSource = "capture_source"
        case participants
    }
}

public struct MeetingAgentParticipantInput: Codable, Equatable, Sendable {
    public var name: String
    public var role: String?
    public var speaker: String?

    public init(name: String, role: String? = nil, speaker: String? = nil) {
        self.name = name
        self.role = role
        self.speaker = speaker
    }
}

public struct MeetingAgentTranscriptInput: Codable, Equatable, Sendable {
    public var language: String
    public var plainText: String
    public var segments: [MeetingAgentTranscriptSegmentInput]

    public init(language: String, plainText: String, segments: [MeetingAgentTranscriptSegmentInput]) {
        self.language = language
        self.plainText = plainText
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey {
        case language
        case plainText = "plain_text"
        case segments
    }
}

public struct MeetingAgentTranscriptSegmentInput: Codable, Equatable, Sendable {
    public var id: String
    public var startMs: Int
    public var endMs: Int
    public var speaker: String
    public var text: String

    public init(id: String, startMs: Int, endMs: Int, speaker: String, text: String) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.speaker = speaker
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case id
        case startMs = "start_ms"
        case endMs = "end_ms"
        case speaker
        case text
    }
}

public struct MeetingAgentAttachmentInput: Codable, Equatable, Sendable {
    public var id: String
    public var fileName: String
    public var mediaType: String
    public var sizeBytes: Int64
    public var sha256: String
    public var sourcePath: String

    public init(
        id: String,
        fileName: String,
        mediaType: String,
        sizeBytes: Int64,
        sha256: String,
        sourcePath: String
    ) {
        self.id = id
        self.fileName = fileName
        self.mediaType = mediaType
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.sourcePath = sourcePath
    }

    enum CodingKeys: String, CodingKey {
        case id
        case fileName = "file_name"
        case mediaType = "media_type"
        case sizeBytes = "size_bytes"
        case sha256
        case sourcePath = "source_path"
    }
}

public struct MeetingAgentAnalysisInput: Codable, Equatable, Sendable {
    public var goal: String
    public var language: String

    public init(goal: String, language: String) {
        self.goal = goal
        self.language = language
    }
}

public struct MeetingAgentOutputInput: Codable, Equatable, Sendable {
    public var reportFormat: String
    public var todosFormat: String
    public var locale: String

    public init(reportFormat: String = "html", todosFormat: String = "json", locale: String = "zh-CN") {
        self.reportFormat = reportFormat
        self.todosFormat = todosFormat
        self.locale = locale
    }

    enum CodingKeys: String, CodingKey {
        case reportFormat = "report_format"
        case todosFormat = "todos_format"
        case locale
    }
}

public enum MeetingAgentRemoteJobStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

public struct MeetingAgentSubmitResponse: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var jobID: String
    public var requestID: String
    public var status: MeetingAgentRemoteJobStatus

    public init(schemaVersion: String, jobID: String, requestID: String, status: MeetingAgentRemoteJobStatus) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.requestID = requestID
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case jobID = "job_id"
        case requestID = "request_id"
        case status
    }
}

public struct MeetingAgentJobStatusResponse: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var jobID: String
    public var requestID: String
    public var meetingID: String
    public var provider: String
    public var status: MeetingAgentRemoteJobStatus
    public var createdAt: String
    public var updatedAt: String
    public var startedAt: String?
    public var completedAt: String?
    public var error: MeetingAgentRemoteJobError?

    public init(
        schemaVersion: String,
        jobID: String,
        requestID: String,
        meetingID: String,
        provider: String,
        status: MeetingAgentRemoteJobStatus,
        createdAt: String,
        updatedAt: String,
        startedAt: String?,
        completedAt: String?,
        error: MeetingAgentRemoteJobError?
    ) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.requestID = requestID
        self.meetingID = meetingID
        self.provider = provider
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case jobID = "job_id"
        case requestID = "request_id"
        case meetingID = "meeting_id"
        case provider
        case status
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case error
    }
}

public struct MeetingAgentRemoteJobError: Codable, Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct MeetingAgentProviderDescriptor: Codable, Equatable, Sendable {
    public var name: String
    public var runID: String

    public init(name: String, runID: String) {
        self.name = name
        self.runID = runID
    }

    enum CodingKeys: String, CodingKey {
        case name
        case runID = "run_id"
    }
}

public struct MeetingAgentResultResponse: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var jobID: String
    public var requestID: String
    public var meetingID: String
    public var requestHash: String
    public var provider: MeetingAgentProviderDescriptor
    public var resultPath: String
    public var manifestPath: String
    public var manifestSHA256: String

    public init(
        schemaVersion: String,
        jobID: String,
        requestID: String,
        meetingID: String,
        requestHash: String,
        provider: MeetingAgentProviderDescriptor,
        resultPath: String,
        manifestPath: String,
        manifestSHA256: String
    ) {
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.requestID = requestID
        self.meetingID = meetingID
        self.requestHash = requestHash
        self.provider = provider
        self.resultPath = resultPath
        self.manifestPath = manifestPath
        self.manifestSHA256 = manifestSHA256
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case jobID = "job_id"
        case requestID = "request_id"
        case meetingID = "meeting_id"
        case requestHash = "request_hash"
        case provider
        case resultPath = "result_path"
        case manifestPath = "manifest_path"
        case manifestSHA256 = "manifest_sha256"
    }
}

public struct MeetingAgentAPIErrorResponse: Codable, Equatable, Sendable {
    public var error: MeetingAgentAPIErrorBody

    public init(error: MeetingAgentAPIErrorBody) {
        self.error = error
    }
}

public struct MeetingAgentAPIErrorBody: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var details: [MeetingAgentJSONValue]

    public init(code: String, message: String, details: [MeetingAgentJSONValue]) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public enum MeetingAgentJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([MeetingAgentJSONValue])
    case object([String: MeetingAgentJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([MeetingAgentJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: MeetingAgentJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "不支持的 JSON 值")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

extension MeetingAgentJSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}
