import AItingjiCore
import Foundation

struct MeetingAgentContextUsage: Equatable, Sendable {
    let estimatedTokens: Int
    let tokenBudget: Int
    let includedHistoryMessages: Int
    let omittedHistoryMessages: Int
    let wasCompacted: Bool

    var percentage: Int {
        min(100, Int((Double(estimatedTokens) / Double(tokenBudget) * 100).rounded()))
    }

    var activityDescription: String {
        let compaction = wasCompacted ? "，已压缩较早内容" : ""
        return "上下文：约 \(estimatedTokens.formatted()) / \(tokenBudget.formatted()) tokens（\(percentage)%）\(compaction)"
    }
}

struct MeetingAgentBuiltContext: Equatable, Sendable {
    let prompt: String
    let usage: MeetingAgentContextUsage
}

enum MeetingAgentContextBuilder {
    static let tokenBudget = 24_000

    static func buildPrompt(
        meeting: Meeting,
        segments: [TranscriptSegment],
        minutesMarkdown: String?,
        people: [VoiceprintPerson],
        currentUserPersonID: VoiceprintPerson.ID?,
        terminology: [TerminologyEntry],
        history: [MeetingAgentChatMessage],
        knowledgeContext: String,
        question: String
    ) -> String {
        buildContext(
            meeting: meeting,
            segments: segments,
            minutesMarkdown: minutesMarkdown,
            people: people,
            currentUserPersonID: currentUserPersonID,
            terminology: terminology,
            history: history,
            knowledgeContext: knowledgeContext,
            question: question
        ).prompt
    }

    static func buildContext(
        meeting: Meeting,
        segments: [TranscriptSegment],
        minutesMarkdown: String?,
        people: [VoiceprintPerson],
        currentUserPersonID: VoiceprintPerson.ID?,
        terminology: [TerminologyEntry],
        history: [MeetingAgentChatMessage],
        knowledgeContext: String,
        question: String
    ) -> MeetingAgentBuiltContext {
        let transcript = bounded(
            segments
                .sorted { $0.startMs < $1.startMs }
                .map(transcriptLine)
                .joined(separator: "\n"),
            limit: 9_000
        )
        let minutes = bounded(minutesMarkdown?.trimmedNonempty ?? "无会议纪要", limit: 3_500)
        let activePeople = people.filter(\.isActive)
        let currentUser = activePeople.first { $0.id == currentUserPersonID }
        let peopleContext = bounded(
            activePeople
                .map { person in
                    let aliases = person.aliases.isEmpty ? "无" : person.aliases.joined(separator: "、")
                    let title = person.jobTitle.trimmedNonempty ?? "未设置"
                    let roles = person.roleTags.isEmpty ? "未设置" : person.roleTags.joined(separator: "、")
                    let identity = person.id == currentUserPersonID ? "；身份：当前用户本人" : ""
                    return "- \(person.displayName)；称呼：\(aliases)；岗位：\(title)；角色：\(roles)\(identity)"
                }
                .joined(separator: "\n"),
            limit: 2_000
        )
        let terminologyContext = bounded(
            terminology
                .filter(\.isActive)
                .map { entry in
                    let aliases = entry.aliases.isEmpty ? "无" : entry.aliases.joined(separator: "、")
                    let category = entry.category.trimmedNonempty ?? "未分类"
                    let notes = entry.notes.trimmedNonempty.map { "；说明：\($0)" } ?? ""
                    return "- \(entry.canonicalName)；别称：\(aliases)；类别：\(category)\(notes)"
                }
                .joined(separator: "\n"),
            limit: 1_000
        )
        let activeHistory = history.filter {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let recentHistory = Array(activeHistory.suffix(6))
        let olderHistory = activeHistory.dropLast(recentHistory.count)
        let olderSummary = olderHistory.suffix(12).map { message in
            let excerpt = bounded(message.content, limit: 320)
                .replacingOccurrences(of: "\n", with: " ")
            return "- \(message.role == .user ? "用户" : "Agent")：\(excerpt)"
        }.joined(separator: "\n")
        let recentConversation = recentHistory.map { message in
            "\(message.role == .user ? "用户" : "Agent")：\(bounded(message.content, limit: 1_500))"
        }.joined(separator: "\n")
        let conversationSource = [
            olderSummary.isEmpty ? nil : "较早聊天压缩摘要：\n\(olderSummary)",
            recentConversation.isEmpty ? nil : "最近聊天：\n\(recentConversation)",
        ].compactMap { $0 }.joined(separator: "\n\n")
        let conversation = bounded(conversationSource, limit: 4_000)
        let knowledge = bounded(
            knowledgeContext.trimmedNonempty ?? "本次未提供 Dify 知识库检索结果。",
            limit: 3_500
        )
        let boundedQuestion = bounded(question, limit: 1_500)

        let prompt = """
        你是 AgendAI 会小纪内嵌的会议 Agent。回答时综合当前会议转写、已生成会议纪要、本地人员库、常用词库和可选 Dify 检索结果。
        人员库和常用词库用于理解姓名、称呼、岗位、项目及专有名词；它们不是会议结论的证据。会议结论优先以转写为准，会议纪要用于结构化辅助；冲突时指出冲突并以转写原文为准。
        区分会议原话、知识库事实和你的分析。没有依据时明确说无法确认，不得把推断伪装成会议结论。回答使用中文，先给结论，再给依据；引用转写时带时间。

        【会议】
        标题：\(meeting.title)
        状态：\(meeting.status.rawValue)

        【当前用户】
        \(currentUser.map { "\($0.displayName)（人员库中的本人）" } ?? "未设置")

        【会议转写】
        \(transcript.trimmedNonempty ?? "无转写内容")

        【会议纪要】
        \(minutes)

        【人员库】
        \(peopleContext.trimmedNonempty ?? "无启用人员")

        【常用词库】
        \(terminologyContext.trimmedNonempty ?? "无启用常用词")

        【Dify 知识库检索结果】
        \(knowledge)

        【近期聊天】
        \(conversation.trimmedNonempty ?? "无")

        【本次问题】
        \(boundedQuestion)
        """
        let omittedHistoryCount = max(0, activeHistory.count - recentHistory.count)
        let wasCompacted = omittedHistoryCount > 0
            || transcript.count < segments.map(transcriptLine).joined(separator: "\n").count
            || conversation.count < conversationSource.count
            || minutes.count < (minutesMarkdown?.count ?? 0)
            || knowledge.count < knowledgeContext.count
        return MeetingAgentBuiltContext(
            prompt: prompt,
            usage: MeetingAgentContextUsage(
                estimatedTokens: estimatedTokens(prompt),
                tokenBudget: tokenBudget,
                includedHistoryMessages: recentHistory.count,
                omittedHistoryMessages: omittedHistoryCount,
                wasCompacted: wasCompacted
            )
        )
    }

    static func buildContinuationContext(
        meeting: Meeting,
        people: [VoiceprintPerson],
        currentUserPersonID: VoiceprintPerson.ID?,
        knowledgeContext: String,
        question: String
    ) -> MeetingAgentBuiltContext {
        let currentUser = people.first { $0.isActive && $0.id == currentUserPersonID }
        let knowledge = bounded(
            knowledgeContext.trimmedNonempty ?? "本轮未提供 Dify 知识库检索结果。",
            limit: 3_500
        )
        let boundedQuestion = bounded(question, limit: 1_500)
        let prompt = """
        你正在继续 AgendAI 会小纪中同一场会议的 Pi Agent 会话。会议转写、会议纪要、人员库、常用词库和此前聊天已经存在于会话上下文中，不要要求用户重复提供，也不要复述无关旧内容。

        【本轮上下文刷新】
        会议：\(meeting.title)
        状态：\(meeting.status.rawValue)
        当前用户：\(currentUser.map { "\($0.displayName)（人员库中的本人）" } ?? "未设置")

        【本轮 Dify 知识库检索结果】
        \(knowledge)

        【本次问题】
        \(boundedQuestion)
        """
        return MeetingAgentBuiltContext(
            prompt: prompt,
            usage: MeetingAgentContextUsage(
                estimatedTokens: estimatedTokens(prompt),
                tokenBudget: tokenBudget,
                includedHistoryMessages: 0,
                omittedHistoryMessages: 0,
                wasCompacted: false
            )
        )
    }

    static func initialActivity(
        segmentCount: Int,
        hasMinutes: Bool,
        peopleCount: Int,
        terminologyCount: Int
    ) -> [String] {
        [
            "已载入会议转写：\(segmentCount) 段",
            hasMinutes ? "已载入会议纪要" : "当前会议暂无纪要",
            "已载入人员库：\(peopleCount) 名",
            "已载入常用词库：\(terminologyCount) 条"
        ]
    }

    private static func transcriptLine(_ segment: TranscriptSegment) -> String {
        let minutes = segment.startMs / 60_000
        let seconds = (segment.startMs / 1_000) % 60
        let speaker = segment.personName?.trimmedNonempty
            ?? segment.speakerLabel.trimmedNonempty
            ?? "未知发言人"
        let text = segment.finalText.trimmedNonempty
            ?? segment.processedText.trimmedNonempty
            ?? segment.rawText
        return String(format: "[%02d:%02d] %@：%@", minutes, seconds, speaker, text)
    }

    private static func bounded(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let headCount = limit * 2 / 3
        let tailCount = limit - headCount
        return """
        \(text.prefix(headCount))
        …（上下文过长，中间内容已省略）…
        \(text.suffix(tailCount))
        """
    }

    private static func estimatedTokens(_ text: String) -> Int {
        max(1, (text.utf8.count + 2) / 3)
    }
}

private extension String {
    var trimmedNonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
