import AItingjiCore
import Foundation

struct MeetingMinutesVocabulary: Equatable, Sendable {
    private struct Replacement: Equatable, Sendable {
        var alias: String
        var canonicalName: String
    }

    static let empty = MeetingMinutesVocabulary(terminologyEntries: [], people: [])

    let terminologyEntries: [TerminologyEntry]
    let people: [VoiceprintPerson]
    private let replacements: [Replacement]
    private let canonicalNames: [String]

    init(terminologyEntries: [TerminologyEntry], people: [VoiceprintPerson]) {
        self.terminologyEntries = terminologyEntries.filter(\.isActive)
        self.people = people.filter(\.isActive)
        canonicalNames = Array(Set(
            self.terminologyEntries.map(\.canonicalName) + self.people.map(\.displayName)
        ))
        .filter { !$0.isEmpty }
        .sorted { $0.count > $1.count }

        var mappedAliases: [String: Replacement] = [:]
        let pairs = self.people.flatMap { person in
            person.aliases.map { ($0, person.displayName) }
        } + self.terminologyEntries.flatMap { entry in
            entry.aliases.map { ($0, entry.canonicalName) }
        }
        for (aliasValue, canonicalValue) in pairs {
            let alias = aliasValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let canonicalName = canonicalValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !alias.isEmpty,
                  !canonicalName.isEmpty,
                  alias.caseInsensitiveCompare(canonicalName) != .orderedSame else {
                continue
            }
            let key = alias.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "zh_CN")
            )
            if mappedAliases[key] == nil {
                mappedAliases[key] = Replacement(alias: alias, canonicalName: canonicalName)
            }
        }
        replacements = mappedAliases.values.sorted {
            if $0.alias.count != $1.alias.count {
                return $0.alias.count > $1.alias.count
            }
            return $0.alias.localizedStandardCompare($1.alias) == .orderedAscending
        }
    }

    var promptContext: String {
        var lines: [String] = []
        if !terminologyEntries.isEmpty {
            lines.append("专有名词映射：")
            for entry in terminologyEntries {
                let aliases = entry.aliases.isEmpty ? "无" : entry.aliases.joined(separator: "、")
                let category = entry.category.isEmpty ? "未分类" : entry.category
                lines.append("- 标准名称：\(entry.canonicalName)；别称：\(aliases)；类别：\(category)")
            }
        }
        if !people.isEmpty {
            lines.append("人员称呼映射：")
            for person in people {
                let aliases = person.aliases.isEmpty ? "无" : person.aliases.joined(separator: "、")
                let jobTitle = person.jobTitle.isEmpty ? "岗位未设置" : person.jobTitle
                let roles = person.roleTags.isEmpty ? "角色未设置" : person.roleTags.joined(separator: "、")
                let zentao = person.zentaoAccount.isEmpty ? "禅道未映射" : "禅道账号 \(person.zentaoAccount)"
                lines.append("- 标准姓名：\(person.displayName)；称呼：\(aliases)；岗位：\(jobTitle)；角色：\(roles)；\(zentao)")
            }
        }
        guard !lines.isEmpty else { return "" }
        return """
        请先按以下本地词库理解转写，并在所有输出字段中只使用标准名称。岗位、角色和禅道账号仅用于识别人员，不要写入纪要正文，除非会议原文明确讨论这些信息。

        \(lines.joined(separator: "\n"))
        """
    }

    func normalize(_ text: String) -> String {
        guard !text.isEmpty, !replacements.isEmpty else { return text }
        var output = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let searchRange = cursor..<text.endIndex
            var canonicalMatch: Range<String.Index>?
            for canonicalName in canonicalNames {
                guard let range = text.range(
                    of: canonicalName,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange,
                    locale: Locale(identifier: "zh_CN")
                ) else { continue }
                if canonicalMatch == nil || range.lowerBound < canonicalMatch!.lowerBound {
                    canonicalMatch = range
                }
                if range.lowerBound == cursor {
                    break
                }
            }

            var replacementMatch: (range: Range<String.Index>, canonicalName: String)?
            for replacement in replacements {
                guard let range = text.range(
                    of: replacement.alias,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchRange,
                    locale: Locale(identifier: "zh_CN")
                ) else { continue }
                if replacementMatch == nil || range.lowerBound < replacementMatch!.range.lowerBound {
                    replacementMatch = (range, replacement.canonicalName)
                }
                if range.lowerBound == cursor {
                    break
                }
            }

            if let canonicalMatch,
               replacementMatch == nil || canonicalMatch.lowerBound <= replacementMatch!.range.lowerBound {
                output.append(contentsOf: text[cursor..<canonicalMatch.lowerBound])
                output.append(contentsOf: text[canonicalMatch])
                cursor = canonicalMatch.upperBound
                continue
            }
            if let replacementMatch {
                output.append(contentsOf: text[cursor..<replacementMatch.range.lowerBound])
                output.append(contentsOf: replacementMatch.canonicalName)
                cursor = replacementMatch.range.upperBound
                continue
            }
            output.append(contentsOf: text[cursor...])
            break
        }
        return output
    }

    func normalize(_ draft: MeetingMinutesModelDraft) -> MeetingMinutesModelDraft {
        MeetingMinutesModelDraft(
            meetingTitle: draft.meetingTitle.map(normalize),
            meetingType: draft.meetingType.map(normalize),
            backgroundAndPurpose: draft.backgroundAndPurpose.map(normalize),
            expectedProblem: draft.expectedProblem.map(normalize),
            participants: draft.participants?.map {
                MeetingMinutesParticipant(
                    name: normalize($0.name),
                    role: normalize($0.role),
                    evidence: normalize($0.evidence),
                    status: normalize($0.status)
                )
            },
            subtitle: normalize(draft.subtitle),
            summary: normalize(draft.summary),
            mainTopics: draft.mainTopics?.map {
                MeetingMinutesMainTopic(
                    topic: normalize($0.topic),
                    details: normalize($0.details),
                    timeRange: $0.timeRange.map(normalize),
                    question: $0.question.map(normalize),
                    viewpoints: $0.viewpoints?.map {
                        MeetingMinutesViewpoint(
                            speaker: normalize($0.speaker),
                            viewpoint: normalize($0.viewpoint),
                            basis: normalize($0.basis),
                            evidence: $0.evidence.map(normalize)
                        )
                    },
                    discussionSteps: $0.discussionSteps?.map {
                        MeetingMinutesDiscussionStep(
                            kind: normalize($0.kind),
                            speaker: normalize($0.speaker),
                            content: normalize($0.content),
                            timeRange: normalize($0.timeRange),
                            evidence: normalize($0.evidence)
                        )
                    },
                    discussionProcess: $0.discussionProcess.map(normalize),
                    outcome: $0.outcome.map(normalize),
                    status: $0.status.map(normalize),
                    evidence: $0.evidence.map(normalize)
                )
            },
            keyFacts: draft.keyFacts?.map {
                MeetingMinutesKeyFact(
                    item: normalize($0.item),
                    value: normalize($0.value),
                    nature: normalize($0.nature),
                    context: normalize($0.context),
                    evidence: normalize($0.evidence)
                )
            },
            conclusions: draft.conclusions.map {
                MeetingMinutesConclusion(
                    topic: normalize($0.topic),
                    conclusion: normalize($0.conclusion),
                    status: $0.status.map(normalize),
                    rationale: $0.rationale.map(normalize),
                    scope: $0.scope.map(normalize),
                    evidence: $0.evidence.map(normalize)
                )
            },
            actions: draft.actions.map {
                MeetingMinutesAction(
                    action: normalize($0.action),
                    owners: $0.owners.map(normalize),
                    deadline: normalize($0.deadline),
                    deliverable: $0.deliverable.map(normalize),
                    dependencies: $0.dependencies?.map(normalize),
                    acceptanceCriteria: $0.acceptanceCriteria.map(normalize),
                    status: $0.status.map(normalize),
                    evidence: $0.evidence.map(normalize)
                )
            },
            risks: draft.risks.map {
                MeetingMinutesRisk(
                    risk: normalize($0.risk),
                    impact: normalize($0.impact),
                    mitigation: normalize($0.mitigation),
                    category: $0.category.map(normalize),
                    nextStep: $0.nextStep.map(normalize),
                    evidence: $0.evidence.map(normalize)
                )
            },
            milestones: draft.milestones.map {
                MeetingMinutesMilestone(date: normalize($0.date), target: normalize($0.target))
            },
            archiveItems: draft.archiveItems.map(normalize)
        )
    }

    func normalize(_ document: MeetingMinutesDocument) -> MeetingMinutesDocument {
        MeetingMinutesDocument(
            meetingID: document.meetingID,
            title: normalize(document.title),
            meetingName: normalize(document.meetingName),
            meetingDate: document.meetingDate,
            meetingTime: document.meetingTime,
            duration: document.duration,
            participants: document.participants.map(normalize),
            participantDetails: document.participantDetails?.map {
                MeetingMinutesParticipant(
                    name: normalize($0.name),
                    role: normalize($0.role),
                    evidence: normalize($0.evidence),
                    status: normalize($0.status)
                )
            },
            sources: document.sources.map(normalize),
            meetingType: document.meetingType.map(normalize),
            backgroundAndPurpose: document.backgroundAndPurpose.map(normalize),
            expectedProblem: document.expectedProblem.map(normalize),
            subtitle: normalize(document.subtitle),
            summary: normalize(document.summary),
            mainTopics: document.mainTopics?.map {
                MeetingMinutesMainTopic(
                    topic: normalize($0.topic),
                    details: normalize($0.details),
                    timeRange: $0.timeRange.map(normalize),
                    question: $0.question.map(normalize),
                    viewpoints: $0.viewpoints?.map {
                        MeetingMinutesViewpoint(
                            speaker: normalize($0.speaker),
                            viewpoint: normalize($0.viewpoint),
                            basis: normalize($0.basis),
                            evidence: $0.evidence.map(normalize)
                        )
                    },
                    discussionSteps: $0.discussionSteps?.map {
                        MeetingMinutesDiscussionStep(
                            kind: normalize($0.kind),
                            speaker: normalize($0.speaker),
                            content: normalize($0.content),
                            timeRange: normalize($0.timeRange),
                            evidence: normalize($0.evidence)
                        )
                    },
                    discussionProcess: $0.discussionProcess.map(normalize),
                    outcome: $0.outcome.map(normalize),
                    status: $0.status.map(normalize),
                    evidence: $0.evidence.map(normalize)
                )
            },
            keyFacts: document.keyFacts?.map {
                MeetingMinutesKeyFact(
                    item: normalize($0.item),
                    value: normalize($0.value),
                    nature: normalize($0.nature),
                    context: normalize($0.context),
                    evidence: normalize($0.evidence)
                )
            },
            conclusions: document.conclusions.map {
                MeetingMinutesConclusion(
                    topic: normalize($0.topic),
                    conclusion: normalize($0.conclusion),
                    status: $0.status.map(normalize),
                    rationale: $0.rationale.map(normalize),
                    scope: $0.scope.map(normalize),
                    evidence: $0.evidence.map(normalize)
                )
            },
            actions: document.actions.map {
                MeetingMinutesAction(
                    action: normalize($0.action),
                    owners: $0.owners.map(normalize),
                    deadline: normalize($0.deadline),
                    deliverable: $0.deliverable.map(normalize),
                    dependencies: $0.dependencies?.map(normalize),
                    acceptanceCriteria: $0.acceptanceCriteria.map(normalize),
                    status: $0.status.map(normalize),
                    evidence: $0.evidence.map(normalize)
                )
            },
            risks: document.risks.map {
                MeetingMinutesRisk(
                    risk: normalize($0.risk),
                    impact: normalize($0.impact),
                    mitigation: normalize($0.mitigation),
                    category: $0.category.map(normalize),
                    nextStep: $0.nextStep.map(normalize),
                    evidence: $0.evidence.map(normalize)
                )
            },
            milestones: document.milestones.map {
                MeetingMinutesMilestone(date: normalize($0.date), target: normalize($0.target))
            },
            archiveItems: document.archiveItems.map(normalize),
            sensitiveNote: normalize(document.sensitiveNote),
            preparedDate: document.preparedDate
        )
    }
}
