import Foundation

struct MeetingMinutesPresentationModel: Equatable, Sendable {
    struct Overview: Equatable, Sendable {
        var meetingName: String
        var date: String
        var time: String
        var location: String
        var participants: [String]
        var meetingType: String
        var sources: [String]
    }

    struct AgendaItem: Identifiable, Equatable, Sendable {
        let id: String
        var index: Int
        var topic: String
        var timeRange: String
        var question: String?
        var process: String
        var viewpoints: [MeetingMinutesViewpoint]
        var outcome: String
        var status: String
        var evidence: String
    }

    struct ConclusionItem: Identifiable, Equatable, Sendable {
        let id: String
        var topic: String
        var conclusion: String
        var status: String
        var rationale: String
        var scope: String
        var evidence: String
    }

    struct UnresolvedItem: Identifiable, Equatable, Sendable {
        let id: String
        var category: String
        var item: String
        var impact: String
        var handling: String
        var nextStep: String
        var owner: String
        var deadline: String
        var evidence: String
    }

    struct ActionItem: Identifiable, Equatable, Sendable {
        let id: String
        var action: String
        var owners: [String]
        var deliverable: String
        var deadline: String
        var deadlineStatus: String
        var dependencies: [String]
        var acceptanceCriteria: String
        var status: String
        var evidence: String
    }

    struct Milestone: Identifiable, Equatable, Sendable {
        let id: String
        var date: String
        var target: String
    }

    var title: String
    var overview: Overview
    var summary: String
    var background: String?
    var expectedProblem: String?
    var agendas: [AgendaItem]
    var conclusions: [ConclusionItem]
    var unresolvedItems: [UnresolvedItem]
    var actions: [ActionItem]
    var milestones: [Milestone]
    var archiveItems: [String]
    var sensitiveNote: String
    var preparedDate: String

    init(document: MeetingMinutesDocument) {
        title = document.title
        overview = Overview(
            meetingName: Self.value(document.meetingName),
            date: Self.value(document.meetingDate),
            time: [Self.value(document.duration), Self.value(document.meetingTime)]
                .filter { $0 != Self.unconfirmed }
                .joined(separator: "；"),
            location: "未记录",
            participants: document.participantDetails?.compactMap { participant in
                let name = Self.optionalValue(participant.name)
                guard let name else { return nil }
                let role = Self.optionalValue(participant.role)
                return role.map { "\(name)（\($0)）" } ?? name
            } ?? document.participants.map(Self.value),
            meetingType: Self.value(document.meetingType),
            sources: document.sources.map(Self.value)
        )
        summary = Self.value(document.summary)
        background = Self.optionalValue(document.backgroundAndPurpose)
        expectedProblem = Self.optionalValue(document.expectedProblem)

        agendas = Self.effectiveTopics(document).enumerated().map { index, topic in
            AgendaItem(
                id: "agenda-\(index)-\(topic.topic)",
                index: index + 1,
                topic: Self.value(topic.topic),
                timeRange: Self.value(topic.timeRange),
                question: Self.optionalValue(topic.question),
                process: Self.topicProcess(topic),
                viewpoints: topic.viewpoints ?? [],
                outcome: Self.value(topic.outcome),
                status: Self.value(topic.status),
                evidence: Self.value(topic.evidence ?? topic.timeRange)
            )
        }

        conclusions = document.conclusions.enumerated().map { index, conclusion in
            ConclusionItem(
                id: "conclusion-\(index)-\(conclusion.topic)",
                topic: Self.value(conclusion.topic),
                conclusion: Self.value(conclusion.conclusion),
                status: Self.value(conclusion.status),
                rationale: Self.value(conclusion.rationale),
                scope: Self.value(conclusion.scope),
                evidence: Self.value(conclusion.evidence ?? conclusion.rationale)
            )
        }

        unresolvedItems = document.risks.enumerated().map { index, risk in
            UnresolvedItem(
                id: "unresolved-\(index)-\(risk.risk)",
                category: Self.value(risk.category),
                item: Self.value(risk.risk),
                impact: Self.value(risk.impact),
                handling: Self.value(risk.mitigation),
                nextStep: Self.value(risk.nextStep),
                owner: Self.unconfirmed,
                deadline: Self.unconfirmed,
                evidence: Self.value(risk.evidence)
            )
        }

        actions = document.actions.enumerated().map { index, action in
            let deadline = Self.value(action.deadline)
            let confirmed = Self.optionalValue(action.deadline) != nil
                && deadline != Self.unconfirmed
            return ActionItem(
                id: "action-\(index)-\(action.action)",
                action: Self.value(action.action),
                owners: action.owners.isEmpty ? [Self.unconfirmed] : action.owners.map(Self.value),
                deliverable: Self.value(action.deliverable),
                deadline: deadline,
                deadlineStatus: confirmed ? "已明确" : "未明确",
                dependencies: action.dependencies?.map(Self.value) ?? [],
                acceptanceCriteria: Self.value(action.acceptanceCriteria),
                status: Self.value(action.status),
                evidence: Self.value(action.evidence)
            )
        }

        milestones = document.milestones.enumerated().map { index, milestone in
            Milestone(
                id: "milestone-\(index)-\(milestone.date)",
                date: Self.value(milestone.date),
                target: Self.value(milestone.target)
            )
        }
        archiveItems = document.archiveItems.map(Self.value)
        sensitiveNote = Self.value(document.sensitiveNote)
        preparedDate = Self.value(document.preparedDate)
    }

    private static let unconfirmed = "待确认"

    private static func value(_ value: String?) -> String {
        optionalValue(value) ?? unconfirmed
    }

    private static func optionalValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "待确认",
              trimmed != "暂无" else { return nil }
        return trimmed
    }

    private static func effectiveTopics(_ document: MeetingMinutesDocument) -> [MeetingMinutesMainTopic] {
        let topics = (document.mainTopics ?? []).filter {
            optionalValue($0.topic) != nil || optionalValue($0.details) != nil
        }
        guard topics.isEmpty else { return topics }
        return [MeetingMinutesMainTopic(
            topic: document.subtitle.isEmpty ? document.meetingName : document.subtitle,
            details: document.summary
        )]
    }

    private static func topicProcess(_ topic: MeetingMinutesMainTopic) -> String {
        if let process = optionalValue(topic.discussionProcess) {
            return process
        }
        let steps = (topic.discussionSteps ?? []).compactMap { step -> String? in
            guard let content = optionalValue(step.content) else { return nil }
            guard let speaker = optionalValue(step.speaker) else { return content }
            return "\(speaker)：\(content)"
        }
        if !steps.isEmpty {
            return steps.joined(separator: "；")
        }
        return value(topic.details)
    }
}
