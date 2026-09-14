import AItingjiCore
import Testing
@testable import AItingjiApp

@Suite("Meeting minutes presentation")
struct MeetingMinutesPresentationTests {
    @Test("maps missing metadata and follow-up ownership to explicit defaults")
    func mapsCompatibilityDefaults() {
        let document = MeetingMinutesDocument(
            meetingID: "meeting-1",
            title: "项目评审",
            meetingName: "项目评审会",
            meetingDate: "2026年9月14日",
            meetingTime: "10:00-10:30",
            duration: "约30分钟",
            participants: ["张三"],
            sources: ["会议转写"],
            subtitle: "方案评审",
            summary: "确认方案边界。",
            conclusions: [],
            actions: [],
            risks: [MeetingMinutesRisk(
                risk: "资料尚未齐全",
                impact: "可能影响评审结论",
                mitigation: "补齐资料",
                nextStep: "下次会议复核"
            )],
            milestones: [],
            archiveItems: [],
            sensitiveNote: "无",
            preparedDate: "2026年9月14日"
        )

        let model = MeetingMinutesPresentationModel(document: document)

        #expect(model.overview.location == "未记录")
        #expect(model.unresolvedItems.first?.owner == "待确认")
        #expect(model.unresolvedItems.first?.deadline == "待确认")
        #expect(model.unresolvedItems.first?.nextStep == "下次会议复核")
        #expect(model.actions.isEmpty)
    }

    @Test("maps agenda discussion process and deadline status")
    func mapsAgendaAndActions() {
        let document = MeetingMinutesDocument(
            meetingID: "meeting-2",
            title: "交付安排",
            meetingName: "交付安排",
            meetingDate: "2026年9月14日",
            meetingTime: "14:00-15:00",
            duration: "约60分钟",
            participants: ["李四"],
            sources: ["会议转写"],
            subtitle: "交付安排",
            summary: "确认交付节点。",
            mainTopics: [MeetingMinutesMainTopic(
                topic: "现场准备",
                details: "确认现场准备项。",
                discussionProcess: "先确认资料，再安排现场检查。",
                outcome: "按计划推进。"
            )],
            conclusions: [],
            actions: [MeetingMinutesAction(
                action: "整理资料",
                owners: ["李四"],
                deadline: "2026年9月20日",
                deliverable: "资料清单"
            )],
            risks: [],
            milestones: [],
            archiveItems: [],
            sensitiveNote: "无",
            preparedDate: "2026年9月14日"
        )

        let model = MeetingMinutesPresentationModel(document: document)

        #expect(model.agendas.first?.process == "先确认资料，再安排现场检查。")
        #expect(model.agendas.first?.outcome == "按计划推进。")
        #expect(model.actions.first?.deadlineStatus == "已明确")
        #expect(model.actions.first?.owners == ["李四"])
    }
}
