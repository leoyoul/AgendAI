import AItingjiCore
import AppKit
import SwiftUI

struct MeetingAgentChatView: View {
    private static let conversationBottomID = "meeting-agent-conversation-bottom"

    @Environment(AppState.self) private var appState
    @State private var draft = ""
    @State private var usesKnowledgeBase = false
    @State private var scrollTask: Task<Void, Never>?
    @State private var visibleMessageLimit = 24

    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionBar
            Divider()
            conversation
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.openURL, OpenURLAction(handler: openAgentLink))
        .onAppear {
            usesKnowledgeBase = hasUsableKnowledgeBase
            appState.refreshMeetingAgentContextUsage(meeting.id)
        }
        .onDisappear {
            scrollTask?.cancel()
        }
        .onChange(of: meeting.id) { _, _ in
            visibleMessageLimit = 24
        }
    }

    private var messages: [MeetingAgentChatMessage] {
        appState.meetingAgentMessagesByMeeting[meeting.id, default: []]
    }

    private var isResponding: Bool {
        appState.isMeetingAgentResponding(meeting.id)
    }

    private var visibleMessages: [MeetingAgentChatMessage] {
        Array(messages.suffix(visibleMessageLimit))
    }

    private var hiddenMessageCount: Int {
        max(0, messages.count - visibleMessages.count)
    }

    private var sessionBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(agentModelSource == nil ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
            if let source = agentModelSource {
                Text(source.selectedModel ?? source.name)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text("未配置 Agent 模型")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }

            Spacer()

            Text("\(segmentCount) 段")
            Text(hasMinutes ? "会议纪要" : "无纪要")
            Text("\(activePeopleCount) 人")
            Text("\(activeTerminologyCount) 词")
            if let stats = appState.meetingAgentSessionStatsByMeeting[meeting.id],
               let tokens = stats.contextTokens,
               let window = stats.contextWindow {
                Text("\(tokens.formatted()) / \(window.formatted()) tokens")
                    .foregroundStyle((stats.contextPercent ?? 0) >= 80 ? .orange : .secondary)
                    .help("Pi 真实上下文；累计工具调用 \(stats.toolCalls) 次")
            } else if let usage = appState.meetingAgentContextUsageByMeeting[meeting.id] {
                Text("本轮 \(usage.estimatedTokens.formatted()) / \(usage.tokenBudget.formatted()) tokens")
                    .foregroundStyle(usage.wasCompacted ? .orange : .secondary)
                    .help(usage.activityDescription)
            }
            if isResponding {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if messages.isEmpty {
                    ContentUnavailableView(
                        "询问这场会议",
                        systemImage: "terminal",
                        description: Text(emptyConversationDescription)
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        if hiddenMessageCount > 0 {
                            Button {
                                visibleMessageLimit += 24
                            } label: {
                                Label(
                                    "加载更早消息（剩余 \(hiddenMessageCount) 条）",
                                    systemImage: "chevron.up"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                        ForEach(visibleMessages) { message in
                            MeetingAgentMessageRow(message: message)
                                .equatable()
                        }
                        Color.clear
                            .frame(height: 1)
                            .id(Self.conversationBottomID)
                    }
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                }
            }
            .onAppear {
                scrollToLatest(using: proxy, immediately: true)
            }
            .onChange(of: latestMessageRevision) { _, _ in
                scrollToLatest(using: proxy)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("询问这场会议", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...6)
                .font(.body)
                .onSubmit { send() }

            HStack(spacing: 10) {
                Button(action: selectWorkspace) {
                    Label(workspaceName, systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help(appState.meetingAgentWorkspacePath)

                Toggle(isOn: $usesKnowledgeBase) {
                    Label("Dify", systemImage: "books.vertical")
                        .font(.caption)
                }
                .toggleStyle(.button)
                .disabled(!hasUsableKnowledgeBase)

                Spacer()

                if isResponding {
                    Button {
                        appState.stopMeetingAgentResponse(meeting.id)
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("停止生成")
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                    }
                    .help("发送")
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .disabled(!canSend)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var agentModelSource: ModelSource? {
        appState.modelSources.first { $0.type == .agent && $0.isDefault && $0.enabled }
            ?? appState.modelSources.first { $0.type == .agent && $0.enabled }
    }

    private var hasUsableKnowledgeBase: Bool {
        let configuration = appState.knowledgeBaseConfiguration
        return configuration.enabled && !configuration.selectedKnowledgeBases.isEmpty
    }

    private var segmentCount: Int {
        appState.segmentsByMeeting[meeting.id, default: []].count
    }

    private var hasMinutes: Bool {
        appState.meetingMinutesArtifacts[meeting.id] != nil
    }

    private var activePeopleCount: Int {
        appState.people.lazy.filter(\.isActive).count
    }

    private var activeTerminologyCount: Int {
        appState.terminologyEntries.lazy.filter(\.isActive).count
    }

    private var canSend: Bool {
        appState.isPersistenceAvailable
            && agentModelSource != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isResponding
    }

    private var workspaceName: String {
        URL(fileURLWithPath: appState.meetingAgentWorkspacePath, isDirectory: true).lastPathComponent
    }

    private var latestMessageRevision: String {
        guard let message = messages.last else { return "empty" }
        return [
            String(messages.count),
            message.id,
            String(message.content.count),
            String(message.reasoning.count),
            String(message.activity.count),
            message.status.rawValue,
        ].joined(separator: ":")
    }

    private var emptyConversationDescription: String {
        if agentModelSource == nil {
            return "请先在模型配置中新增、测试并启用默认 Agent 模型。"
        }
        return "转写、会议纪要、人员库和常用词会自动载入；Dify 检索由右上角开关控制。"
    }

    private func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend, !question.isEmpty else { return }
        draft = ""
        appState.sendMeetingAgentQuestion(
            meetingID: meeting.id,
            question: question,
            usesKnowledgeBase: usesKnowledgeBase
        )
    }

    private func selectWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "选择 Agent 工作目录"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(
            fileURLWithPath: appState.meetingAgentWorkspacePath,
            isDirectory: true
        )
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                appState.updateMeetingAgentWorkspace(url)
            }
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy, immediately: Bool = false) {
        scrollTask?.cancel()
        scrollTask = Task { @MainActor in
            if immediately {
                await Task.yield()
            } else {
                try? await Task.sleep(for: .milliseconds(80))
            }
            guard !Task.isCancelled else { return }
            proxy.scrollTo(Self.conversationBottomID, anchor: .bottom)
        }
    }

    private func openAgentLink(_ url: URL) -> OpenURLAction.Result {
        let workspaceURL = URL(
            fileURLWithPath: appState.meetingAgentWorkspacePath,
            isDirectory: true
        )
        switch MeetingAgentLinkResolver.resolve(url, workspaceDirectory: workspaceURL) {
        case .localFile(let fileURL):
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                appState.statusMessage = "文件不存在：\(fileURL.path)"
                return .handled
            }
            guard NSWorkspace.shared.open(fileURL) else {
                appState.statusMessage = "无法打开文件：\(fileURL.path)"
                return .handled
            }
            return .handled
        case .web(let webURL):
            return .systemAction(webURL)
        case .unsupported:
            appState.statusMessage = "不支持的链接：\(url.absoluteString)"
            return .discarded
        }
    }
}

enum MeetingAgentResolvedLink: Equatable {
    case localFile(URL)
    case web(URL)
    case unsupported
}

enum MeetingAgentLinkResolver {
    static func resolve(_ url: URL, workspaceDirectory: URL) -> MeetingAgentResolvedLink {
        if url.isFileURL {
            return .localFile(url.standardizedFileURL)
        }
        if let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" {
                return .web(url)
            }
            return .unsupported
        }

        let path = (url.path.removingPercentEncoding ?? url.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return .unsupported }
        if path.hasPrefix("/") {
            return .localFile(URL(fileURLWithPath: path).standardizedFileURL)
        }

        let workspace = workspaceDirectory.standardizedFileURL
        let fileURL = workspace.appendingPathComponent(path).standardizedFileURL
        let workspacePrefix = workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
        guard fileURL.path == workspace.path || fileURL.path.hasPrefix(workspacePrefix) else {
            return .unsupported
        }
        return .localFile(fileURL)
    }
}

private struct MeetingAgentMessageRow: View, Equatable {
    let message: MeetingAgentChatMessage

    init(message: MeetingAgentChatMessage) {
        self.message = message
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
    }

    var body: some View {
        let segments = turnSegments
        Group {
            if message.role == .user {
                MeetingAgentUserMessageBubble(content: message.content)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    if segments.isEmpty, message.status == .streaming {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在生成回答")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(segments) { segment in
                            switch segment.kind {
                            case .process:
                                MeetingAgentProcessSegmentView(
                                    segment: segment,
                                    isActive: message.status == .streaming && segment.id == segments.last?.id
                                )
                            case .commentary:
                                MeetingAgentMarkdownView(segment.content, compact: true)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            case .final:
                                MeetingAgentMarkdownView(segment.content)
                                    .font(.body)
                                    .foregroundStyle(message.status == .failed ? .red : .primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 2)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity)
    }

    private var turnSegments: [MeetingAgentTurnSegment] {
        if !message.timeline.isEmpty { return message.timeline }
        var segments: [MeetingAgentTurnSegment] = []
        if !message.activity.isEmpty || !message.reasoning.isEmpty {
            segments.append(MeetingAgentTurnSegment(
                id: "\(message.id)-legacy-process",
                kind: .process,
                reasoning: message.reasoning,
                activity: message.activity
            ))
        }
        if !message.content.isEmpty {
            segments.append(MeetingAgentTurnSegment(
                id: "\(message.id)-legacy-final",
                kind: .final,
                content: message.content
            ))
        }
        return segments
    }
}

private struct MeetingAgentUserMessageBubble: View {
    let content: String

    var body: some View {
        bubble
        .frame(maxWidth: 640, alignment: .trailing)
        .contextMenu {
            Button("复制消息") {
                MeetingAgentPasteboard.copy(content)
            }
        }
    }

    private var bubble: some View {
        Text(attributedContent)
            .lineSpacing(4)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
    }

    private var attributedContent: AttributedString {
        MeetingAgentMarkdownCache.shared.attributedString(for: content)
    }
}

private struct MeetingAgentProcessSegmentView: View {
    @State private var isExpanded = false
    let segment: MeetingAgentTurnSegment
    let isActive: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(segment.activity.indices, id: \.self) { index in
                    Label(segment.activity[index], systemImage: activityIcon(for: segment.activity[index]))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !segment.reasoning.isEmpty {
                    if !segment.activity.isEmpty { Divider() }
                    Text(segment.reasoning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            Button("复制思考内容") {
                                MeetingAgentPasteboard.copy(segment.reasoning)
                            }
                        }
                }
            }
            .padding(.top, 8)
            .padding(.leading, 2)
        } label: {
            HStack(spacing: 7) {
                if isActive {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: processIcon)
                        .foregroundStyle(processColor)
                }
                Text(isActive ? "正在处理" : processSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tint(.secondary)
    }

    private var processSummary: String {
        if let item = segment.activity.last(where: { $0.contains("调用") }) {
            let name = item.split(separator: "：", maxSplits: 1).last.map(String.init) ?? "工具"
            return item.contains("失败") ? "调用失败：\(name)" : "运行了 \(name)"
        }
        if segment.activity.contains(where: { $0.contains("压缩") }) { return "整理上下文" }
        if !segment.reasoning.isEmpty { return "思考" }
        return "准备上下文"
    }

    private var processIcon: String {
        if segment.activity.contains(where: { $0.contains("失败") }) {
            return "exclamationmark.triangle.fill"
        }
        if segment.activity.contains(where: { $0.contains("停止") }) {
            return "stop.circle.fill"
        }
        if segment.activity.contains(where: { $0.contains("调用") }) {
            return "terminal"
        }
        return "chevron.right"
    }

    private var processColor: Color {
        segment.activity.contains(where: { $0.contains("失败") }) ? .red : .secondary
    }

    private func activityIcon(for item: String) -> String {
        if item.contains("失败") { return "exclamationmark.triangle" }
        if item.contains("停止") { return "stop.circle" }
        if item.contains("调用") { return "terminal" }
        return "checkmark"
    }
}

enum MeetingAgentContentBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case unorderedList([String])
    case orderedList(start: Int, items: [String])
    case table(headers: [String], rows: [[String]])
    case quote(String)
    case divider
    case code(language: String?, content: String)
}

enum MeetingAgentContentParser {
    static func parse(_ text: String) -> [MeetingAgentContentBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [MeetingAgentContentBlock] = []
        var paragraphLines: [String] = []
        var lineIndex = 0

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                appendParagraph(&blocks, lines: &paragraphLines)
                let languageText = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var codeLines: [String] = []
                lineIndex += 1
                while lineIndex < lines.count {
                    let codeLine = lines[lineIndex]
                    if codeLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        break
                    }
                    codeLines.append(codeLine)
                    lineIndex += 1
                }
                blocks.append(.code(
                    language: languageText.isEmpty ? nil : languageText,
                    content: codeLines.joined(separator: "\n")
                ))
            } else if let table = table(from: lines, startingAt: lineIndex) {
                appendParagraph(&blocks, lines: &paragraphLines)
                blocks.append(.table(headers: table.headers, rows: table.rows))
                lineIndex = table.nextLineIndex
                continue
            } else if trimmed.isEmpty {
                appendParagraph(&blocks, lines: &paragraphLines)
            } else if let heading = heading(from: trimmed) {
                appendParagraph(&blocks, lines: &paragraphLines)
                blocks.append(.heading(level: heading.level, text: heading.text))
            } else if isDivider(trimmed) {
                appendParagraph(&blocks, lines: &paragraphLines)
                blocks.append(.divider)
            } else if let item = unorderedItem(from: trimmed) {
                appendParagraph(&blocks, lines: &paragraphLines)
                appendUnorderedItem(item, to: &blocks)
            } else if let item = orderedItem(from: trimmed) {
                appendParagraph(&blocks, lines: &paragraphLines)
                appendOrderedItem(number: item.number, text: item.text, to: &blocks)
            } else if trimmed.hasPrefix(">") {
                appendParagraph(&blocks, lines: &paragraphLines)
                let quote = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                appendQuote(quote, to: &blocks)
            } else {
                paragraphLines.append(line)
            }
            lineIndex += 1
        }

        appendParagraph(&blocks, lines: &paragraphLines)
        return blocks.isEmpty ? [.paragraph(text)] : blocks
    }

    private static func table(
        from lines: [String],
        startingAt startIndex: Int
    ) -> (headers: [String], rows: [[String]], nextLineIndex: Int)? {
        let separatorIndex = startIndex + 1
        guard separatorIndex < lines.count,
              let headers = tableCells(from: lines[startIndex]),
              let separators = tableCells(from: lines[separatorIndex]),
              headers.count == separators.count,
              separators.allSatisfy(isTableSeparator) else {
            return nil
        }

        var rows: [[String]] = []
        var nextLineIndex = separatorIndex + 1
        while nextLineIndex < lines.count,
              let cells = tableCells(from: lines[nextLineIndex]) {
            rows.append(normalizedTableRow(cells, columnCount: headers.count))
            nextLineIndex += 1
        }
        return (headers, rows, nextLineIndex)
    }

    private static func tableCells(from line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("|") else { return nil }

        var cells: [String] = []
        var current = ""
        var isEscaped = false
        var isInsideCode = false
        for character in trimmed {
            if isEscaped {
                current.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "`" {
                isInsideCode.toggle()
                current.append(character)
            } else if character == "|", !isInsideCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if isEscaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))

        if trimmed.hasPrefix("|"), cells.first?.isEmpty == true { cells.removeFirst() }
        if trimmed.hasSuffix("|"), cells.last?.isEmpty == true { cells.removeLast() }
        return cells.count >= 2 ? cells : nil
    }

    private static func isTableSeparator(_ cell: String) -> Bool {
        let marker = cell.trimmingCharacters(in: .whitespaces)
        let dashes = marker.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return dashes.count >= 3 && dashes.allSatisfy { $0 == "-" }
    }

    private static func normalizedTableRow(_ cells: [String], columnCount: Int) -> [String] {
        if cells.count == columnCount { return cells }
        if cells.count > columnCount { return Array(cells.prefix(columnCount)) }
        return cells + Array(repeating: "", count: columnCount - cells.count)
    }

    private static func appendParagraph(
        _ blocks: inout [MeetingAgentContentBlock],
        lines: inout [String]
    ) {
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { blocks.append(.paragraph(text)) }
        lines.removeAll(keepingCapacity: true)
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level), line.count > level else { return nil }
        let textStart = line.index(line.startIndex, offsetBy: level)
        guard line[textStart].isWhitespace else { return nil }
        let text = line[textStart...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    private static func unorderedItem(from line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let item = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return item.isEmpty ? nil : item
        }
        return nil
    }

    private static func orderedItem(from line: String) -> (number: Int, text: String)? {
        guard let separator = line.firstIndex(of: ".") else { return nil }
        let numberText = line[..<separator]
        guard !numberText.isEmpty,
              numberText.allSatisfy(\.isNumber),
              let number = Int(numberText) else { return nil }
        let contentStart = line.index(after: separator)
        guard contentStart < line.endIndex, line[contentStart].isWhitespace else { return nil }
        let text = line[contentStart...].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (number, text)
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        return compact == "---" || compact == "***" || compact == "___"
    }

    private static func appendUnorderedItem(
        _ item: String,
        to blocks: inout [MeetingAgentContentBlock]
    ) {
        if case .unorderedList(let items)? = blocks.last {
            blocks[blocks.count - 1] = .unorderedList(items + [item])
        } else {
            blocks.append(.unorderedList([item]))
        }
    }

    private static func appendOrderedItem(
        number: Int,
        text: String,
        to blocks: inout [MeetingAgentContentBlock]
    ) {
        if case .orderedList(let start, let items)? = blocks.last,
           number == start + items.count {
            blocks[blocks.count - 1] = .orderedList(start: start, items: items + [text])
        } else {
            blocks.append(.orderedList(start: number, items: [text]))
        }
    }

    private static func appendQuote(
        _ quote: String,
        to blocks: inout [MeetingAgentContentBlock]
    ) {
        if case .quote(let existing)? = blocks.last {
            blocks[blocks.count - 1] = .quote(existing + "\n" + quote)
        } else {
            blocks.append(.quote(quote))
        }
    }
}

final class MeetingAgentMarkdownCache: @unchecked Sendable {
    static let shared = MeetingAgentMarkdownCache()

    private let blockCache = NSCache<NSString, MeetingAgentContentBlockBox>()
    private let inlineCache = NSCache<NSString, MeetingAgentAttributedStringBox>()

    private init() {
        blockCache.countLimit = 128
        blockCache.totalCostLimit = 8 * 1_024 * 1_024
        inlineCache.countLimit = 512
        inlineCache.totalCostLimit = 4 * 1_024 * 1_024
    }

    func blocks(for content: String) -> [MeetingAgentContentBlock] {
        let key = content as NSString
        if let cached = blockCache.object(forKey: key) {
            return cached.value
        }
        let parsed = MeetingAgentContentParser.parse(content)
        blockCache.setObject(
            MeetingAgentContentBlockBox(parsed),
            forKey: key,
            cost: content.utf8.count
        )
        return parsed
    }

    func attributedString(for text: String) -> AttributedString {
        let key = text as NSString
        if let cached = inlineCache.object(forKey: key) {
            return cached.value
        }
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        let attributed = (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
        inlineCache.setObject(
            MeetingAgentAttributedStringBox(attributed),
            forKey: key,
            cost: text.utf8.count
        )
        return attributed
    }
}

private final class MeetingAgentContentBlockBox: NSObject {
    let value: [MeetingAgentContentBlock]

    init(_ value: [MeetingAgentContentBlock]) {
        self.value = value
    }
}

private final class MeetingAgentAttributedStringBox: NSObject {
    let value: AttributedString

    init(_ value: AttributedString) {
        self.value = value
    }
}

private enum MeetingAgentPasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct MeetingAgentMarkdownView: View {
    let content: String
    let blocks: [MeetingAgentContentBlock]
    let compact: Bool

    init(_ content: String, compact: Bool = false) {
        self.content = content
        blocks = MeetingAgentMarkdownCache.shared.blocks(for: content)
        self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 14) {
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case .paragraph(let text):
                    inlineText(text)
                case .heading(let level, let text):
                    Text(attributedMarkdown(text))
                        .font(headingFont(level))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, compact ? 0 : 2)
                case .unorderedList(let items):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items.indices, id: \.self) { index in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 5))
                                    .foregroundStyle(.secondary)
                                inlineText(items[index])
                            }
                        }
                    }
                    .padding(.leading, 4)
                case .orderedList(let start, let items):
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items.indices, id: \.self) { index in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(start + index).")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 22, alignment: .trailing)
                                inlineText(items[index])
                            }
                        }
                    }
                case .table(let headers, let rows):
                    MeetingAgentMarkdownTable(headers: headers, rows: rows)
                case .quote(let text):
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 3)
                        inlineText(text)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                case .divider:
                    Divider()
                        .padding(.vertical, 2)
                case .code(let language, let content):
                    MeetingAgentCodeBlock(language: language, content: content)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("复制回复") {
                MeetingAgentPasteboard.copy(content)
            }
        }
    }

    private func attributedMarkdown(_ text: String) -> AttributedString {
        MeetingAgentMarkdownCache.shared.attributedString(for: text)
    }

    private func inlineText(_ text: String) -> some View {
        Text(attributedMarkdown(text))
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingFont(_ level: Int) -> Font {
        if compact { return Font.body.weight(.semibold) }
        switch level {
        case 1: return Font.title3.weight(.semibold)
        case 2: return Font.headline.weight(.semibold)
        default: return Font.body.weight(.semibold)
        }
    }
}

private struct MeetingAgentMarkdownTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        VStack(spacing: 0) {
            row(headers, isHeader: true)
            ForEach(rows.indices, id: \.self) { rowIndex in
                row(rows[rowIndex], isHeader: false)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ values: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(values.indices, id: \.self) { index in
                cell(values[index], isHeader: isHeader)
            }
        }
    }

    private func cell(_ content: String, isHeader: Bool) -> some View {
        Text(attributedMarkdown(content))
            .font(isHeader ? .body.weight(.semibold) : .body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .topLeading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(isHeader ? Color.primary.opacity(0.08) : Color.clear)
            .overlay {
                Rectangle()
                    .stroke(Color.secondary.opacity(0.16), lineWidth: 0.5)
            }
    }

    private func attributedMarkdown(_ text: String) -> AttributedString {
        MeetingAgentMarkdownCache.shared.attributedString(for: text)
    }
}

private struct MeetingAgentCodeBlock: View {
    @State private var showsCopied = false
    let language: String?
    let content: String
    let previewContent: String

    init(language: String?, content: String) {
        self.language = language
        self.content = content
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 18 {
            previewContent = lines.prefix(18).joined(separator: "\n") + "\n..."
        } else {
            previewContent = content
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language ?? "代码")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    MeetingAgentPasteboard.copy(content)
                    showsCopied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        showsCopied = false
                    }
                } label: {
                    Image(systemName: showsCopied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help(showsCopied ? "已复制" : "复制代码")
            }
            .padding(.horizontal, 12)
            .frame(height: 34)

            Divider()

            ScrollView(.horizontal) {
                codeText
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        }
    }

    private var codeText: some View {
        Text(previewContent)
            .font(.system(.caption, design: .monospaced))
            .fixedSize(horizontal: true, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
