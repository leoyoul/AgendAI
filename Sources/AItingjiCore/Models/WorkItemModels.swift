import Foundation

public enum WorkItemStatus: String, Codable, CaseIterable, Sendable {
    case pendingConfirmation = "pending_confirmation"
    case notStarted = "not_started"
    case inProgress = "in_progress"
    case completed
    case cancelled

    public var displayName: String {
        switch self {
        case .pendingConfirmation: "待确认"
        case .notStarted: "待开始"
        case .inProgress: "进行中"
        case .completed: "已完成"
        case .cancelled: "已取消"
        }
    }

    public func canTransition(to target: Self) -> Bool {
        // 状态只描述当前工作阶段，不限制用户直接切换到其他阶段。
        _ = target
        return true
    }
}

public enum WorkItemPriority: String, Codable, CaseIterable, Sendable {
    case low
    case normal
    case high

    public var displayName: String {
        switch self {
        case .low: "低"
        case .normal: "普通"
        case .high: "高"
        }
    }
}

public enum WorkItemSource: String, Codable, CaseIterable, Sendable {
    case meetingMinutes = "meeting_minutes"
    case meetingAnalysis = "meeting_analysis"
    case meetingAgent = "meeting_agent"
    case manual

    public var displayName: String {
        switch self {
        case .meetingMinutes: "会议纪要行动项"
        case .meetingAnalysis: "AI 分析任务"
        case .meetingAgent: "Agent 结构化待办"
        case .manual: "手动创建"
        }
    }
}

/// 工作台的纵轴组织方式。该设置只影响展示，不改变工作项数据。
public enum WorkbenchLaneMode: String, Codable, CaseIterable, Sendable {
    case people
    case mixed

    public var displayName: String {
        switch self {
        case .people: "按人员"
        case .mixed: "混合"
        }
    }
}

/// 工作台中的统一工作项。计划日期只表达日期，不表达时间。
public struct WorkItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var deliverable: String
    public var acceptanceCriteria: String
    public var ownerPersonIDs: [VoiceprintPerson.ID]
    public var ownerNameHints: [String]
    public var sourceDeadlineText: String?
    public var plannedStartDate: Date?
    public var plannedEndDate: Date?
    public var status: WorkItemStatus
    public var priority: WorkItemPriority
    public var tags: [String]
    public var completionNote: String
    public var completedAt: Date?
    public var sourceMeetingID: Meeting.ID?
    public var sourceMeetingTitle: String?
    public var source: WorkItemSource
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        title: String,
        detail: String = "",
        deliverable: String = "",
        acceptanceCriteria: String = "",
        ownerPersonIDs: [VoiceprintPerson.ID] = [],
        ownerNameHints: [String] = [],
        sourceDeadlineText: String? = nil,
        plannedStartDate: Date? = nil,
        plannedEndDate: Date? = nil,
        status: WorkItemStatus = .notStarted,
        priority: WorkItemPriority = .normal,
        tags: [String] = [],
        completionNote: String = "",
        completedAt: Date? = nil,
        sourceMeetingID: Meeting.ID? = nil,
        sourceMeetingTitle: String? = nil,
        source: WorkItemSource = .manual,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.deliverable = deliverable
        self.acceptanceCriteria = acceptanceCriteria
        self.ownerPersonIDs = Array(NSOrderedSet(array: ownerPersonIDs)) as? [String] ?? ownerPersonIDs
        self.ownerNameHints = ownerNameHints
        self.sourceDeadlineText = sourceDeadlineText
        self.plannedStartDate = plannedStartDate.map { WorkItemDate.normalized($0) }
        self.plannedEndDate = plannedEndDate.map { WorkItemDate.normalized($0) }
        self.status = status
        self.priority = priority
        self.tags = tags
        self.completionNote = completionNote
        self.completedAt = completedAt
        self.sourceMeetingID = sourceMeetingID
        self.sourceMeetingTitle = sourceMeetingTitle
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public var isScheduled: Bool {
        plannedStartDate != nil || plannedEndDate != nil
    }

    /// A work item can enter the calendar only after its confirmation fields are complete.
    /// The application layer additionally validates that the owner is an active person.
    public var isCalendarReady: Bool {
        guard status != .pendingConfirmation,
              ownerPersonIDs.count == 1,
              let end = plannedEndDate else { return false }
        let start = plannedStartDate ?? end
        return WorkItemDate.normalized(start) <= WorkItemDate.normalized(end)
    }

    public var needsConfirmation: Bool {
        !isCalendarReady || status == .pendingConfirmation
    }

    public func isOverdue(on date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard status != .completed, status != .cancelled,
              let plannedEndDate else { return false }
        return WorkItemDate.normalized(plannedEndDate, calendar: calendar)
            < WorkItemDate.normalized(date, calendar: calendar)
    }
}

public struct WorkItemOrigin: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var workItemID: WorkItem.ID
    public var source: WorkItemSource
    public var sourceKey: String
    public var meetingID: Meeting.ID?
    public var meetingTitle: String?
    public var jobID: MeetingAgentJob.ID?
    public var todoID: String?
    public var rawTitle: String
    public var rawOwnerNames: [String]
    public var rawDeadline: String?
    public var evidence: [MeetingTodoEvidence]
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        workItemID: WorkItem.ID,
        source: WorkItemSource,
        sourceKey: String,
        meetingID: Meeting.ID? = nil,
        meetingTitle: String? = nil,
        jobID: MeetingAgentJob.ID? = nil,
        todoID: String? = nil,
        rawTitle: String,
        rawOwnerNames: [String] = [],
        rawDeadline: String? = nil,
        evidence: [MeetingTodoEvidence] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.workItemID = workItemID
        self.source = source
        self.sourceKey = sourceKey
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.jobID = jobID
        self.todoID = todoID
        self.rawTitle = rawTitle
        self.rawOwnerNames = rawOwnerNames
        self.rawDeadline = rawDeadline
        self.evidence = evidence
        self.createdAt = createdAt
    }
}

public struct WorkItemImportCandidate: Sendable {
    public var item: WorkItem
    public var origin: WorkItemOrigin

    public init(item: WorkItem, origin: WorkItemOrigin) {
        self.item = item
        self.origin = origin
    }
}

public struct WorkItemFilter: Equatable, Sendable {
    public var query: String
    public var statuses: Set<WorkItemStatus>
    public var ownerPersonIDs: Set<VoiceprintPerson.ID>
    public var priorities: Set<WorkItemPriority>
    public var startDate: Date?
    public var endDate: Date?

    public init(
        query: String = "",
        statuses: Set<WorkItemStatus> = [],
        ownerPersonIDs: Set<VoiceprintPerson.ID> = [],
        priorities: Set<WorkItemPriority> = [],
        startDate: Date? = nil,
        endDate: Date? = nil
    ) {
        self.query = query
        self.statuses = statuses
        self.ownerPersonIDs = ownerPersonIDs
        self.priorities = priorities
        self.startDate = startDate
        self.endDate = endDate
    }
}

public enum WorkItemDate {
    public static func normalized(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    public static func addingDays(
        _ value: Date,
        _ days: Int,
        calendar: Calendar = .current
    ) -> Date {
        calendar.date(byAdding: .day, value: days, to: normalized(value, calendar: calendar))
            .map { normalized($0, calendar: calendar) }
            ?? normalized(value, calendar: calendar)
    }

    public static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: normalized(date, calendar: calendar))
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    public static func date(from key: String, calendar: Calendar = .current) -> Date? {
        let values = key.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
    }
}

public enum WorkItemDateParser {
    public static func parse(
        _ rawValue: String?,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let fullPattern = #"(\d{4})\s*[年./-]\s*(\d{1,2})\s*[月./-]\s*(\d{1,2})\s*日?"#
        let fullValues = captureValues(in: value, pattern: fullPattern)
        if fullValues.count == 3,
           let date = strictDate(year: fullValues[0], month: fullValues[1], day: fullValues[2], calendar: calendar) {
            return date
        }

        let monthDayPattern = #"(\d{1,2})\s*月\s*(\d{1,2})\s*日?"#
        let values = captureValues(in: value, pattern: monthDayPattern)
        if values.count == 2 {
            let year = calendar.component(.year, from: referenceDate)
            return strictDate(year: year, month: values[0], day: values[1], calendar: calendar)
        }

        let numericMonthDayPattern = #"(\d{1,2})\s*[./-]\s*(\d{1,2})"#
        let numericValues = captureValues(in: value, pattern: numericMonthDayPattern)
        if numericValues.count == 2 {
            let year = calendar.component(.year, from: referenceDate)
            return strictDate(year: year, month: numericValues[0], day: numericValues[1], calendar: calendar)
        }
        return nil
    }

    private static func strictDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let normalized = calendar.dateComponents([.year, .month, .day], from: date)
        guard normalized.year == year, normalized.month == month, normalized.day == day else {
            return nil
        }
        return calendar.startOfDay(for: date)
    }

    private static func captureValues(in value: String, pattern: String) -> [Int] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = expression.firstMatch(in: value, range: range) else { return [] }
        return (1..<match.numberOfRanges).compactMap { index in
            let captureRange = match.range(at: index)
            guard let swiftRange = Range(captureRange, in: value) else { return nil }
            return Int(value[swiftRange])
        }
    }
}
