import Foundation

public enum MeetingAgentJobStatus: String, Codable, CaseIterable, Sendable {
    case submitting
    case queued
    case running
    case importing
    case ready
    case failed
    case cancelled
}

public enum MeetingTodoConfirmationStatus: String, Codable, CaseIterable, Sendable {
    case pendingConfirmation = "pending_confirmation"
    case confirmed
    case ignored
}

public enum MeetingTodoWorkflow: String, Codable, CaseIterable, Sendable {
    case none
    case zentao
}

public struct MeetingAgentJob: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var meetingID: Meeting.ID
    public var requestHash: String
    public var provider: String
    public var status: MeetingAgentJobStatus
    public var analysisGoal: String
    public var resultRelativePath: String?
    public var errorCode: String?
    public var errorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    public init(
        id: String,
        meetingID: Meeting.ID,
        requestHash: String,
        provider: String,
        status: MeetingAgentJobStatus = .submitting,
        analysisGoal: String = "",
        resultRelativePath: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        createdAt: Date,
        updatedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.requestHash = requestHash
        self.provider = provider
        self.status = status
        self.analysisGoal = analysisGoal
        self.resultRelativePath = resultRelativePath
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.completedAt = completedAt
    }
}

public struct MeetingAgentResult: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var jobID: MeetingAgentJob.ID
    public var meetingID: Meeting.ID
    public var manifestRelativePath: String
    public var reportRelativePath: String
    public var manifestSHA256: String
    public var importedAt: Date

    public init(
        id: String,
        jobID: MeetingAgentJob.ID,
        meetingID: Meeting.ID,
        manifestRelativePath: String,
        reportRelativePath: String,
        manifestSHA256: String,
        importedAt: Date
    ) {
        self.id = id
        self.jobID = jobID
        self.meetingID = meetingID
        self.manifestRelativePath = manifestRelativePath
        self.reportRelativePath = reportRelativePath
        self.manifestSHA256 = manifestSHA256
        self.importedAt = importedAt
    }
}

public struct MeetingTodoEvidence: Codable, Equatable, Sendable {
    public var segmentID: TranscriptSegment.ID
    public var quote: String
    public var timeRange: String

    private enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case quote
        case timeRange = "time_range"
    }

    public init(segmentID: TranscriptSegment.ID, quote: String, timeRange: String) {
        self.segmentID = segmentID
        self.quote = quote
        self.timeRange = timeRange
    }
}

public struct MeetingTodoIdentity: Codable, Hashable, Sendable {
    public var jobID: MeetingAgentJob.ID
    public var todoID: String

    public init(jobID: MeetingAgentJob.ID, todoID: String) {
        self.jobID = jobID
        self.todoID = todoID
    }
}

public struct MeetingTodo: Codable, Identifiable, Equatable, Sendable {
    public var id: MeetingTodoIdentity { MeetingTodoIdentity(jobID: jobID, todoID: todoID) }
    public var todoID: String
    public var jobID: MeetingAgentJob.ID
    public var meetingID: Meeting.ID
    public var title: String
    public var detail: String
    public var owner: String?
    public var deadline: String?
    public var deliverable: String?
    public var acceptanceCriteria: String?
    public var evidence: [MeetingTodoEvidence]
    public var confirmationStatus: MeetingTodoConfirmationStatus
    public var proposedWorkflow: MeetingTodoWorkflow
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        jobID: MeetingAgentJob.ID,
        meetingID: Meeting.ID,
        title: String,
        detail: String = "",
        owner: String? = nil,
        deadline: String? = nil,
        deliverable: String? = nil,
        acceptanceCriteria: String? = nil,
        evidence: [MeetingTodoEvidence] = [],
        confirmationStatus: MeetingTodoConfirmationStatus = .pendingConfirmation,
        proposedWorkflow: MeetingTodoWorkflow = .none,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        todoID = id
        self.jobID = jobID
        self.meetingID = meetingID
        self.title = title
        self.detail = detail
        self.owner = owner
        self.deadline = deadline
        self.deliverable = deliverable
        self.acceptanceCriteria = acceptanceCriteria
        self.evidence = evidence
        self.confirmationStatus = confirmationStatus
        self.proposedWorkflow = proposedWorkflow
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }
}

public enum MeetingAgentChatRole: String, Codable, CaseIterable, Sendable {
    case user
    case assistant
}

public enum MeetingAgentChatStatus: String, Codable, CaseIterable, Sendable {
    case completed
    case streaming
    case failed
    case cancelled
}

public enum MeetingAgentTurnSegmentKind: String, Codable, CaseIterable, Sendable {
    case process
    case commentary
    case final
}

public struct MeetingAgentTurnSegment: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var kind: MeetingAgentTurnSegmentKind
    public var content: String
    public var reasoning: String
    public var activity: [String]

    public init(
        id: String = UUID().uuidString,
        kind: MeetingAgentTurnSegmentKind,
        content: String = "",
        reasoning: String = "",
        activity: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.reasoning = reasoning
        self.activity = activity
    }
}

public struct MeetingAgentChatMessage: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var meetingID: Meeting.ID
    public var role: MeetingAgentChatRole
    public var content: String
    public var reasoning: String
    public var activity: [String]
    public var timeline: [MeetingAgentTurnSegment]
    public var status: MeetingAgentChatStatus
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        meetingID: Meeting.ID,
        role: MeetingAgentChatRole,
        content: String,
        reasoning: String = "",
        activity: [String] = [],
        timeline: [MeetingAgentTurnSegment] = [],
        status: MeetingAgentChatStatus = .completed,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.activity = activity
        self.timeline = timeline
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public mutating func appendAgentActivity(_ text: String) {
        guard activity.last != text else { return }
        activity.append(text)
        if activity.count > 40 {
            activity.removeFirst(activity.count - 40)
        }
        if timeline.last?.kind == .process {
            guard timeline[timeline.count - 1].activity.last != text else { return }
            timeline[timeline.count - 1].activity.append(text)
        } else {
            timeline.append(MeetingAgentTurnSegment(kind: .process, activity: [text]))
        }
    }

    public mutating func appendAgentReasoning(_ delta: String, limit: Int = 24_000) {
        guard !delta.isEmpty else { return }
        reasoning = Self.bounded(reasoning + delta, limit: limit)
        if timeline.last?.kind != .process {
            timeline.append(MeetingAgentTurnSegment(kind: .process))
        }
        let index = timeline.count - 1
        timeline[index].reasoning = Self.bounded(timeline[index].reasoning + delta, limit: limit)
    }

    public mutating func appendAgentText(_ delta: String) {
        guard !delta.isEmpty else { return }
        content += delta
        if timeline.last?.kind == .commentary {
            timeline[timeline.count - 1].content += delta
        } else {
            timeline.append(MeetingAgentTurnSegment(kind: .commentary, content: delta))
        }
    }

    public mutating func completeAgentTurn(finalText: String) {
        let finalText = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if finalText.isEmpty {
            content = "Agent 未返回可显示的回答。"
            timeline.append(MeetingAgentTurnSegment(kind: .final, content: content))
            status = .failed
        } else {
            content = finalText
            if let index = timeline.lastIndex(where: { $0.kind == .commentary || $0.kind == .final }) {
                timeline[index].kind = .final
                timeline[index].content = finalText
            } else {
                timeline.append(MeetingAgentTurnSegment(kind: .final, content: finalText))
            }
            status = .completed
        }
        appendRootActivity("回答完成")
    }

    public mutating func appendRootActivity(_ text: String) {
        guard activity.last != text else { return }
        activity.append(text)
        if activity.count > 40 {
            activity.removeFirst(activity.count - 40)
        }
    }

    private static func bounded(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return "…" + text.suffix(limit)
    }

    private enum CodingKeys: String, CodingKey {
        case id, meetingID, role, content, reasoning, activity, timeline, status, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        meetingID = try container.decode(Meeting.ID.self, forKey: .meetingID)
        role = try container.decode(MeetingAgentChatRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        activity = try container.decodeIfPresent([String].self, forKey: .activity) ?? []
        timeline = try container.decodeIfPresent([MeetingAgentTurnSegment].self, forKey: .timeline) ?? []
        status = try container.decode(MeetingAgentChatStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}
