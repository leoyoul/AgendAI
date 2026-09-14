import SwiftUI

struct MeetingMinutesDocumentView: View {
    let model: MeetingMinutesPresentationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            documentHeader
            overviewSection
            summarySection
            agendaSection
            conclusionsSection
            unresolvedSection
            actionsSection
            milestonesSection
            archiveSection
        }
        .frame(maxWidth: 920, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .textSelection(.enabled)
    }

    private var documentHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.title)
                .font(.system(size: 28, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("会议纪要 · \(model.preparedDate)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var overviewSection: some View {
        MinutesSection(title: "会议概览", systemImage: "info.circle") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 14) {
                metadata("会议名称", model.overview.meetingName, "text.book.closed")
                metadata("会议日期", model.overview.date, "calendar")
                metadata("会议时间", model.overview.time, "clock")
                metadata("会议地点", model.overview.location, "mappin.and.ellipse")
                metadata("会议类型", model.overview.meetingType, "tag")
                metadata("会议依据", model.overview.sources.joined(separator: "；"), "doc.text")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("参会人员")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                FlowingTextList(values: model.overview.participants)
            }
        }
    }

    private var summarySection: some View {
        MinutesSection(title: "会议摘要", systemImage: "text.alignleft") {
            Text(model.summary)
                .font(.body)
                .lineSpacing(4)
            if let background = model.background {
                labeledParagraph("背景与目的", background)
            }
            if let expectedProblem = model.expectedProblem {
                labeledParagraph("需要解决的问题", expectedProblem)
            }
        }
    }

    private var agendaSection: some View {
        MinutesSection(title: "会议议程与讨论", systemImage: "list.number") {
            if model.agendas.isEmpty {
                EmptyMinutesLine(text: "暂无可确认的议题")
            } else {
                VStack(spacing: 10) {
                    ForEach(model.agendas) { item in
                        MeetingMinutesAgendaRow(item: item)
                    }
                }
            }
        }
    }

    private var conclusionsSection: some View {
        MinutesSection(title: "会议结论", systemImage: "checkmark.seal") {
            if model.conclusions.isEmpty {
                EmptyMinutesLine(text: "暂无明确结论")
            } else {
                VStack(spacing: 10) {
                    ForEach(model.conclusions) { item in
                        MeetingMinutesConclusionRow(item: item)
                    }
                }
            }
        }
    }

    private var unresolvedSection: some View {
        MinutesSection(title: "未决事项", systemImage: "exclamationmark.triangle") {
            if model.unresolvedItems.isEmpty {
                EmptyMinutesLine(text: "暂无明确未决事项")
            } else {
                VStack(spacing: 10) {
                    ForEach(model.unresolvedItems) { item in
                        MeetingMinutesUnresolvedRow(item: item)
                    }
                }
            }
        }
    }

    private var actionsSection: some View {
        MinutesSection(title: "已确定待办", systemImage: "checklist") {
            if model.actions.isEmpty {
                EmptyMinutesLine(text: "暂无明确待办")
            } else {
                VStack(spacing: 10) {
                    ForEach(model.actions) { item in
                        MeetingMinutesActionRow(item: item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var milestonesSection: some View {
        if !model.milestones.isEmpty {
            MinutesSection(title: "时间节点", systemImage: "calendar.badge.clock") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.milestones) { milestone in
                        HStack(alignment: .top, spacing: 12) {
                            Text(milestone.date)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.tint)
                                .frame(width: 120, alignment: .leading)
                            Text(milestone.target)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var archiveSection: some View {
        if !model.archiveItems.isEmpty || !model.sensitiveNote.isEmpty {
            MinutesSection(title: "归档与说明", systemImage: "archivebox") {
                if !model.archiveItems.isEmpty {
                    labeledParagraph("归档资料", model.archiveItems.joined(separator: "、"))
                }
                if !model.sensitiveNote.isEmpty {
                    Text(model.sensitiveNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func metadata(_ title: String, _ value: String, _ systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value.isEmpty ? "待确认" : value)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 20)
        }
    }

    private func labeledParagraph(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .lineSpacing(3)
        }
    }
}

private struct MinutesSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.title3.weight(.semibold))
            content
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct MeetingMinutesAgendaRow: View {
    @State private var isExpanded = true
    let item: MeetingMinutesPresentationModel.AgendaItem

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                if let question = item.question {
                    labeled("讨论焦点", question)
                }
                labeled("讨论过程", item.process)
                if !item.viewpoints.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("主要观点")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(item.viewpoints.enumerated()), id: \.offset) { _, viewpoint in
                            Text("\(viewpoint.speaker)：\(viewpoint.viewpoint)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                labeled("形成结果", item.outcome)
                HStack(spacing: 8) {
                    StatusPill(text: item.status, tint: .orange)
                    Text("依据：\(item.evidence)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(String(format: "%02d", item.index))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.tint)
                    .frame(width: 24, alignment: .leading)
                Text(item.topic)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(item.timeRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .lineSpacing(3)
        }
    }
}

private struct MeetingMinutesConclusionRow: View {
    let item: MeetingMinutesPresentationModel.ConclusionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.topic)
                    .font(.headline)
                Spacer()
                StatusPill(text: item.status, tint: .green)
            }
            Text(item.conclusion)
            labeled("形成依据", item.rationale)
            labeled("适用范围", item.scope)
            evidence(item.evidence)
        }
        .padding(14)
        .background(.background.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(title)：")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
        }
    }

    private func evidence(_ value: String) -> some View {
        Text("依据：\(value)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct MeetingMinutesUnresolvedRow: View {
    @Environment(AppState.self) private var appState
    let item: MeetingMinutesPresentationModel.UnresolvedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.item)
                    .font(.headline)
                Spacer()
                StatusPill(text: item.category, tint: .orange)
            }
            labeled("可能影响", item.impact)
            labeled("处理要求", item.handling)
            labeled("下一步", item.nextStep)
            HStack(spacing: 16) {
                Label(item.owner, systemImage: "person")
                Label(item.deadline, systemImage: "calendar")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("依据：\(item.evidence)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(.orange.opacity(0.22), lineWidth: 1)
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}

private struct MeetingMinutesActionRow: View {
    @Environment(AppState.self) private var appState
    let item: MeetingMinutesPresentationModel.ActionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.action)
                    .font(.headline)
                Spacer()
                StatusPill(text: item.deadlineStatus, tint: item.deadlineStatus == "已明确" ? .green : .orange)
            }
            HStack(spacing: 16) {
                Label(item.owners.joined(separator: "、"), systemImage: "person.2")
                Label(item.deadline, systemImage: "calendar")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            labeled("交付物", item.deliverable)
            if !item.dependencies.isEmpty {
                labeled("依赖", item.dependencies.joined(separator: "、"))
            }
            labeled("验收标准", item.acceptanceCriteria)
            Text("状态：\(item.status) · 依据：\(item.evidence)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(.green.opacity(0.2), lineWidth: 1)
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
        }
    }
}

private struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct FlowingTextList: View {
    let values: [String]

    var body: some View {
        if values.isEmpty {
            Text("待确认")
                .foregroundStyle(.secondary)
        } else {
            Text(values.joined(separator: "、"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct EmptyMinutesLine: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "minus.circle")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
