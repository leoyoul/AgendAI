import AItingjiCore

extension WorkspaceDestination: Identifiable {
    public var id: Self { self }

    static let sidebarDestinations: [WorkspaceDestination] = [
        .calendar,
        .agentSettings,
        .knowledgeBase,
        .models,
        .vocabulary,
        .people,
        .archive,
        .debugLog
    ]

    var title: String {
        switch self {
        case .calendar: "日历"
        case .agentSettings: "Agent 设置"
        case .models: "模型"
        case .knowledgeBase: "知识库"
        case .vocabulary: "常用词"
        case .people: "人员"
        case .archive: "归档"
        case .debugLog: "调试日志"
        case .meeting: "会议"
        }
    }

    var systemImage: String {
        switch self {
        case .calendar: "calendar"
        case .agentSettings: "cpu"
        case .models: "server.rack"
        case .knowledgeBase: "books.vertical"
        case .vocabulary: "character.book.closed"
        case .people: "person.2"
        case .archive: "archivebox"
        case .debugLog: "ladybug"
        case .meeting: "waveform"
        }
    }
}
