import AItingjiCore
import Foundation

struct MeetingAnalysisArtifact: Equatable, Sendable {
    var document: MeetingAnalysisDocument
    var markdown: String
    var html: String
}

struct MeetingAnalysisDocument: Codable, Equatable, Sendable {
    var meetingID: Meeting.ID
    var title: String
    var generatedAt: Date
    var executiveSummary: String
    var findings: [MeetingAnalysisFinding]
    var todos: [MeetingAnalysisTodo]
    var risks: [String]
    var sources: [String]
}

struct MeetingAnalysisFinding: Codable, Equatable, Sendable {
    var topic: String
    var analysis: String
    var basis: String
}

struct MeetingAnalysisTodo: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var item: String
    var owner: String
    var task: String
    var deliverable: String
    var deadline: String
    var assignmentBasis: String
    var evidence: String
}

struct MeetingAnalysisGenerator: Sendable {
    typealias AgentResponseGenerator = @Sendable (
        _ source: ModelSource,
        _ prompt: String,
        _ runtime: PiAgentRuntimeConfiguration
    ) async throws -> String

    private let storageDirectory: URL
    private let now: @Sendable () -> Date
    private let agentResponseGenerator: AgentResponseGenerator

    init(
        storageDirectory: URL = Self.defaultStorageDirectory(),
        now: @escaping @Sendable () -> Date = Date.init,
        agentResponseGenerator: @escaping AgentResponseGenerator = { source, prompt, runtime in
            var completedText = ""
            for try await event in PiAgentRPCClient().stream(
                source: source,
                prompt: prompt,
                runtime: runtime
            ) {
                if case .completed(let content) = event {
                    completedText = content
                }
            }
            guard !completedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingAnalysisGenerationError.emptyResponse
            }
            return completedText
        }
    ) {
        self.storageDirectory = storageDirectory
        self.now = now
        self.agentResponseGenerator = agentResponseGenerator
    }

    func generate(
        meeting: Meeting,
        segments: [TranscriptSegment],
        originalMinutes: MeetingMinutesArtifact?,
        people: [VoiceprintPerson],
        terminology: [TerminologyEntry],
        knowledgeContext: String,
        source: ModelSource,
        runtime: PiAgentRuntimeConfiguration,
        prompt: String = Self.defaultPrompt
    ) async throws -> MeetingAnalysisArtifact {
        let draft: MeetingAnalysisDraft
        if source.baseURL.hasPrefix("mock://") {
            draft = Self.mockDraft(people: people)
        } else {
            let response = try await agentResponseGenerator(
                source,
                Self.prompt(
                    meeting: meeting,
                    segments: segments,
                    originalMinutes: originalMinutes,
                    people: people,
                    terminology: terminology,
                    knowledgeContext: knowledgeContext,
                    instructions: prompt,
                    now: now()
                ),
                runtime
            )
            draft = try Self.decodeDraft(response)
        }

        let activeNames = Set(people.filter(\.isActive).map(\.displayName))
        let document = MeetingAnalysisDocument(
            meetingID: meeting.id,
            title: draft.title.trimmedNonempty ?? "\(meeting.title) AI 分析会议纪要",
            generatedAt: now(),
            executiveSummary: draft.executiveSummary.trimmedNonempty ?? "暂无可确认的分析结论。",
            findings: draft.findings.filter {
                $0.topic.trimmedNonempty != nil || $0.analysis.trimmedNonempty != nil
            },
            todos: draft.todos.enumerated().compactMap { index, todo in
                guard let item = todo.item.trimmedNonempty,
                      let task = todo.task.trimmedNonempty else { return nil }
                let proposedOwner = todo.owner.trimmedNonempty ?? "待确认"
                let owner = activeNames.contains(proposedOwner) ? proposedOwner : "待确认"
                return MeetingAnalysisTodo(
                    id: todo.id.trimmedNonempty ?? "todo-\(index + 1)",
                    item: item,
                    owner: owner,
                    task: task,
                    deliverable: todo.deliverable.trimmedNonempty ?? "待确认",
                    deadline: todo.deadline.trimmedNonempty ?? "待确认",
                    assignmentBasis: todo.assignmentBasis.trimmedNonempty ?? "待确认",
                    evidence: todo.evidence.trimmedNonempty ?? "待确认"
                )
            },
            risks: draft.risks.compactMap(\.trimmedNonempty),
            sources: draft.sources.compactMap(\.trimmedNonempty)
        )
        let artifact = MeetingAnalysisArtifact(
            document: document,
            markdown: MeetingAnalysisRenderer.markdown(document),
            html: MeetingAnalysisRenderer.html(document)
        )
        try persist(artifact)
        return artifact
    }

    func load(meetingID: Meeting.ID) throws -> MeetingAnalysisArtifact? {
        let url = cachedURL(meetingID: meetingID, pathExtension: "json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(MeetingAnalysisDocument.self, from: Data(contentsOf: url))
        let artifact = MeetingAnalysisArtifact(
            document: document,
            markdown: MeetingAnalysisRenderer.markdown(document),
            html: MeetingAnalysisRenderer.html(document)
        )
        try? persist(artifact)
        return artifact
    }

    func cachedHTMLURL(meetingID: Meeting.ID) -> URL? {
        let url = cachedURL(meetingID: meetingID, pathExtension: "html")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func exportFileName(document: MeetingAnalysisDocument, pathExtension: String) -> String {
        "\(safeFilename(document.title))-AI分析.\(pathExtension)"
    }

    static func defaultStorageDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("会小纪", isDirectory: true)
            .appendingPathComponent("MeetingAnalysis", isDirectory: true)
    }

    static func decodeDraft(_ response: String) throws -> MeetingAnalysisDraft {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let first = trimmed.firstIndex(of: "{"), let last = trimmed.lastIndex(of: "}"), first <= last {
            json = String(trimmed[first...last])
        } else {
            json = trimmed
        }
        guard let data = json.data(using: .utf8) else {
            throw MeetingAnalysisGenerationError.invalidStructuredOutput
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(MeetingAnalysisDraft.self, from: data)
        } catch {
            throw MeetingAnalysisGenerationError.invalidStructuredOutput
        }
    }

    static let defaultPrompt = PostprocessPrompt.meetingAnalysis

    private static func prompt(
        meeting: Meeting,
        segments: [TranscriptSegment],
        originalMinutes: MeetingMinutesArtifact?,
        people: [VoiceprintPerson],
        terminology: [TerminologyEntry],
        knowledgeContext: String,
        instructions: String,
        now: Date
    ) -> String {
        let transcript = MarkdownExporter().export(meeting: meeting, segments: segments)
        let peopleContext = Self.dispatchPriorityPeople(people.filter(\.isActive)).map { person in
            let aliases = person.aliases.isEmpty ? "无" : person.aliases.joined(separator: "、")
            let roles = person.roleTags.isEmpty ? "未设置" : person.roleTags.joined(separator: "、")
            let responsibilities = person.responsibilities.trimmedNonempty ?? "未设置"
            let zentao = person.zentaoAccount.trimmedNonempty ?? "无"
            let priority = zentao == "无" ? "第二优先级：无禅道账号" : "第一优先级：有禅道账号"
            return "- \(priority)；姓名：\(person.displayName)；称呼：\(aliases)；岗位：\(person.jobTitle.trimmedNonempty ?? "未设置")；角色：\(roles)；职责：\(responsibilities)；禅道账号：\(zentao)"
        }.joined(separator: "\n")
        let terms = terminology.filter(\.isActive).map { entry in
            "- \(entry.canonicalName)；别称：\(entry.aliases.joined(separator: "、"))；说明：\(entry.notes)"
        }.joined(separator: "\n")
        let formatter = ISO8601DateFormatter()
        let effectiveInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultPrompt
            : instructions
        return """
        \(effectiveInstructions)

        【任务分工派发规则】
        1. 输出必须包含任务分工派发内容；每条任务的 owner 只能使用下方启用人员的标准姓名，不能输出会议外的人名、禅道账号、用户 ID 或岗位名称。
        2. 会议明确指定的负责人优先保留；会议未明确指定时，先按职责匹配，再优先选择有禅道账号的合适人员，只有没有合适的禅道账号人员时才选择无禅道账号人员。
        3. 人员库中的“第一优先级”表示有禅道账号，“第二优先级”表示无禅道账号；不要因为优先级而把不相关人员强行分派给任务。
        4. 无法从启用人员中可靠匹配负责人时，owner 写“待确认”，并在 assignment_basis 中说明原因；不得编造人员。

        【当前时间】
        \(formatter.string(from: now))

        【会议】
        \(meeting.title)

        【完整转写】
        \(transcript)

        【原始会议纪要】
        \(originalMinutes?.markdown ?? "尚未生成")

        【人员库】
        \(peopleContext.isEmpty ? "无启用人员" : peopleContext)

        【常用词库】
        \(terms.isEmpty ? "无启用常用词" : terms)

        【知识库检索结果】
        \(knowledgeContext.trimmedNonempty ?? "本次没有可用的知识库结果")
        """
    }

    private static func dispatchPriorityPeople(_ people: [VoiceprintPerson]) -> [VoiceprintPerson] {
        let sorted = people.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        return sorted.sorted { hasZentaoAccount($0) && !hasZentaoAccount($1) }
    }

    private static func hasZentaoAccount(_ person: VoiceprintPerson) -> Bool {
        person.zentaoAccount.trimmedNonempty != nil
    }

    private static func mockDraft(people: [VoiceprintPerson]) -> MeetingAnalysisDraft {
        let owner = dispatchPriorityPeople(people.filter(\.isActive)).first?.displayName ?? "待确认"
        return MeetingAnalysisDraft(
            title: "AI 分析会议纪要",
            executiveSummary: "已基于会议资料完成人员职责和后续执行分析。",
            findings: [MeetingAnalysisFinding(topic: "执行安排", analysis: "需要形成明确的责任分工和交付闭环。", basis: "会议转写与人员职责")],
            todos: [MeetingAnalysisTodoDraft(
                id: "todo-1",
                item: "确认后续执行计划",
                owner: owner,
                task: "整理会议确定事项并形成执行计划",
                deliverable: "执行计划清单",
                deadline: "待确认",
                assignmentBasis: owner == "待确认" ? "缺少可匹配人员，待确认" : "职责匹配建议，待确认",
                evidence: "会议转写"
            )],
            risks: [],
            sources: ["会议转写"]
        )
    }

    private func persist(_ artifact: MeetingAnalysisArtifact) throws {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(artifact.document).write(
            to: cachedURL(meetingID: artifact.document.meetingID, pathExtension: "json"),
            options: .atomic
        )
        try artifact.markdown.write(
            to: cachedURL(meetingID: artifact.document.meetingID, pathExtension: "md"),
            atomically: true,
            encoding: .utf8
        )
        try artifact.html.write(
            to: cachedURL(meetingID: artifact.document.meetingID, pathExtension: "html"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func cachedURL(meetingID: Meeting.ID, pathExtension: String) -> URL {
        storageDirectory
            .appendingPathComponent(Self.safeFilename(meetingID))
            .appendingPathExtension(pathExtension)
    }

    private static func safeFilename(_ value: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>")
        let cleaned = value.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "AI分析会议纪要" : cleaned
    }
}

struct MeetingAnalysisDraft: Codable, Equatable, Sendable {
    var title: String
    var executiveSummary: String
    var findings: [MeetingAnalysisFinding]
    var todos: [MeetingAnalysisTodoDraft]
    var risks: [String]
    var sources: [String]
}

struct MeetingAnalysisTodoDraft: Codable, Equatable, Sendable {
    var id: String
    var item: String
    var owner: String
    var task: String
    var deliverable: String
    var deadline: String
    var assignmentBasis: String
    var evidence: String
}

enum MeetingAnalysisRenderer {
    static func markdown(_ document: MeetingAnalysisDocument) -> String {
        var lines = [
            "# \(document.title)",
            "",
            "## 综合分析",
            "",
            document.executiveSummary,
            "",
            "## 分析结论",
            "",
        ]
        if document.findings.isEmpty {
            lines.append("暂无可确认的分析结论。")
        } else {
            for finding in document.findings {
                lines += ["### \(finding.topic)", "", finding.analysis, "", "依据：\(finding.basis)", ""]
            }
        }
        lines += [
            "## 任务分工派发",
            "",
            "| 事项 | 负责人 | 具体任务 | 交付物 | 截止时间 | 分派依据 | 证据 |",
            "| --- | --- | --- | --- | --- | --- | --- |",
        ]
        if document.todos.isEmpty {
            lines.append("| 待确认 | 待确认 | 暂无可确认任务 | 待确认 | 待确认 | 待确认 | 待确认 |")
        } else {
            for todo in document.todos {
                lines.append("| \(escapeTable(todo.item)) | \(escapeTable(todo.owner)) | \(escapeTable(todo.task)) | \(escapeTable(todo.deliverable)) | \(escapeTable(todo.deadline)) | \(escapeTable(todo.assignmentBasis)) | \(escapeTable(todo.evidence)) |")
            }
        }
        lines += ["", "## 风险与待确认", ""]
        lines += document.risks.isEmpty ? ["暂无。"] : document.risks.map { "- \($0)" }
        lines += ["", "## 分析来源", ""]
        lines += document.sources.isEmpty ? ["- 会议转写"] : document.sources.map { "- \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    static func html(_ document: MeetingAnalysisDocument) -> String {
        let findingHTML = document.findings.isEmpty
            ? "<p>暂无可确认的分析结论。</p>"
            : document.findings.map { finding in
                "<h3>\(escapeHTML(finding.topic))</h3><p>\(escapeHTML(finding.analysis))</p><p><strong>依据：</strong>\(escapeHTML(finding.basis))</p>"
            }.joined()
        let todoRows = document.todos.isEmpty
            ? "<tr><td>待确认</td><td>待确认</td><td>暂无可确认任务</td><td>待确认</td><td>待确认</td><td>待确认</td><td>待确认</td></tr>"
            : document.todos.map { todo in
                "<tr><td>\(escapeHTML(todo.item))</td><td><strong>\(escapeHTML(todo.owner))</strong></td><td>\(escapeHTML(todo.task))</td><td>\(escapeHTML(todo.deliverable))</td><td>\(escapeHTML(todo.deadline))</td><td>\(escapeHTML(todo.assignmentBasis))</td><td>\(escapeHTML(todo.evidence))</td></tr>"
            }.joined()
        let risks = document.risks.isEmpty
            ? "<p>暂无。</p>"
            : "<ul>\(document.risks.map { "<li>\(escapeHTML($0))</li>" }.joined())</ul>"
        let sources = document.sources.isEmpty
            ? "<li>会议转写</li>"
            : document.sources.map { "<li>\(escapeHTML($0))</li>" }.joined()
        let title = escapeHTML(document.title)
        let generatedAt = escapeHTML(formatDate(document.generatedAt))
        let meetingID = escapeHTML(document.meetingID)
        let todoCount = document.todos.count
        return """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="source-document" content="AgendAI 会小纪 AI 分析会议纪要">
          <title>\(title)</title>
          <style>
        :root {
          --ink: #142235;
          --ink-strong: #0b1727;
          --muted: #667486;
          --white: #ffffff;
          --line: #dce3e8;
          --teal: #0c9aa8;
          --teal-deep: #08737e;
          --teal-soft: #e7f5f5;
          --coral: #d86d56;
          --shadow: 0 20px 60px rgba(20, 34, 53, 0.08);
        }
        * { box-sizing: border-box; }
        html { scroll-behavior: smooth; }
        body {
          margin: 0;
          color: var(--ink);
          background: #eef2f3;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
          font-size: 16px;
          line-height: 1.75;
          -webkit-font-smoothing: antialiased;
        }
        a { color: var(--teal-deep); text-decoration-thickness: 1px; text-underline-offset: 3px; }
        a:hover { color: var(--coral); }
        .topbar {
          position: fixed;
          z-index: 20;
          inset: 0 0 auto;
          height: 64px;
          display: flex;
          align-items: center;
          gap: 16px;
          padding: 0 28px;
          color: #f7fbfc;
          background: rgba(11, 23, 39, 0.94);
          border-bottom: 1px solid rgba(255,255,255,.1);
          backdrop-filter: blur(14px);
        }
        .brand { display: flex; align-items: center; gap: 12px; min-width: 250px; }
        .brand-mark { width: 9px; height: 34px; background: var(--coral); border-radius: 2px; }
        .brand-title { font-size: 14px; font-weight: 700; letter-spacing: .04em; }
        .brand-subtitle { color: #9eacba; font-size: 12px; margin-top: -3px; }
        .topbar-note { margin-left: auto; color: #aebbc6; font-size: 12px; }
        .menu-toggle { display: none; margin-left: auto; width: 36px; height: 34px; color: #fff; background: transparent; border: 1px solid rgba(255,255,255,.25); border-radius: 4px; }
        .menu-toggle span, .menu-toggle::before, .menu-toggle::after { content: ""; display: block; width: 15px; height: 1px; margin: 3px auto; background: currentColor; }
        .progress-track { position: fixed; z-index: 21; top: 64px; left: 0; right: 0; height: 3px; background: rgba(255,255,255,.08); }
        .progress-value { width: 0; height: 100%; background: var(--coral); transition: width .12s linear; }
        .layout { max-width: 1540px; display: grid; grid-template-columns: 250px minmax(0, 1fr); gap: 28px; margin: 0 auto; padding: 104px 28px 64px; }
        .rail { position: sticky; top: 96px; align-self: start; max-height: calc(100vh - 128px); overflow: auto; padding: 12px 10px 14px 0; scrollbar-width: thin; }
        .rail-kicker { color: var(--teal-deep); font-size: 11px; font-weight: 800; letter-spacing: .16em; text-transform: uppercase; }
        .rail-caption { margin: 7px 0 18px; color: var(--muted); font-size: 13px; line-height: 1.45; }
        .toc { display: grid; gap: 3px; }
        .toc a { display: flex; gap: 10px; align-items: baseline; padding: 8px 10px; color: var(--muted); font-size: 13px; line-height: 1.4; text-decoration: none; border-left: 2px solid transparent; border-radius: 0 4px 4px 0; }
        .toc a:hover { color: var(--ink); background: #e2eaec; }
        .toc a.active { color: var(--teal-deep); background: var(--teal-soft); border-left-color: var(--teal); font-weight: 700; }
        .toc-index { flex: 0 0 23px; color: var(--coral); font-size: 11px; font-variant-numeric: tabular-nums; }
        .main { min-width: 0; }
        .report { overflow: hidden; background: var(--white); border: 1px solid rgba(20,34,53,.08); border-radius: 18px; box-shadow: var(--shadow); }
        .hero { position: relative; overflow: hidden; padding: 66px 70px 58px; color: #f8fbfc; background: var(--ink-strong); border-bottom: 7px solid var(--coral); }
        .hero::before { content: ""; position: absolute; right: -80px; top: -100px; width: 330px; height: 330px; border: 1px solid rgba(86, 199, 202, .25); border-radius: 50%; box-shadow: 0 0 0 28px rgba(86,199,202,.04), 0 0 0 58px rgba(86,199,202,.03); }
        .hero::after { content: ""; position: absolute; left: 58%; right: 0; bottom: 24px; height: 1px; background: rgba(255,255,255,.13); transform: rotate(-8deg); transform-origin: left; }
        .hero > * { position: relative; z-index: 1; }
        .hero-kicker { margin-bottom: 26px; color: #65d0d0; font-size: 11px; font-weight: 800; letter-spacing: .18em; }
        .hero h1 { max-width: 900px; margin: 0 0 34px; color: #fff; font-size: 48px; font-weight: 760; line-height: 1.18; letter-spacing: 0; }
        .hero-meta { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 18px; max-width: 1060px; }
        .hero-meta p { margin: 0; padding-left: 14px; color: #bac7d0; font-size: 13px; line-height: 1.55; border-left: 1px solid rgba(101,208,208,.65); }
        .report-section { padding: 48px 70px 54px; border-top: 1px solid var(--line); }
        .report-section:first-of-type { border-top: 0; }
        .report-section h2 { margin: 0 0 30px; padding-bottom: 16px; color: var(--ink-strong); font-size: 30px; font-weight: 760; line-height: 1.25; border-bottom: 2px solid var(--ink-strong); }
        .report-section h3 { margin: 38px 0 16px; padding-left: 14px; color: var(--teal-deep); font-size: 21px; font-weight: 750; line-height: 1.35; border-left: 4px solid var(--coral); }
        .report-section p { margin: 0 0 16px; }
        .report-section ul, .report-section ol { margin: 10px 0 22px; padding-left: 1.45em; }
        .report-section li { margin: 7px 0; padding-left: 5px; }
        .report-section li::marker { color: var(--coral); font-weight: 700; }
        .report-section strong { color: var(--ink-strong); }
        .report-section blockquote { margin: 24px 0; padding: 20px 24px; color: #29475b; background: var(--teal-soft); border-left: 4px solid var(--teal); }
        .report-section blockquote p:last-child { margin-bottom: 0; }
        .table-wrap { overflow-x: auto; margin: 22px 0 30px; border: 1px solid var(--line); border-radius: 5px; background: #fff; }
        table { width: 100%; min-width: 1080px; border-collapse: collapse; font-size: 13px; line-height: 1.55; }
        th, td { padding: 12px 14px; vertical-align: top; text-align: left; border-bottom: 1px solid var(--line); }
        th { color: var(--ink-strong); background: #e9eff1; font-size: 12px; font-weight: 800; }
        tbody tr:nth-child(even) { background: #f8faf9; }
        tbody tr:last-child td { border-bottom: 0; }
        .document-meta { color: var(--muted); font-size: 13px; }
        @media (max-width: 1000px) {
          .layout { display: block; padding: 92px 18px 40px; }
          .rail { position: fixed; z-index: 15; top: 64px; left: 0; bottom: 0; width: 280px; max-height: none; padding: 26px 22px; background: rgba(247,248,247,.98); border-right: 1px solid var(--line); box-shadow: 16px 0 40px rgba(20,34,53,.12); transform: translateX(-105%); transition: transform .2s ease; }
          body.nav-open .rail { transform: translateX(0); }
          .menu-toggle { display: block; }
          .topbar-note { display: none; }
          .brand { min-width: 0; }
          .hero { padding: 48px 38px 42px; }
          .hero h1 { font-size: 38px; }
          .report-section { padding: 38px 38px 44px; }
        }
        @media (max-width: 620px) {
          body { font-size: 15px; }
          .topbar { height: 58px; padding: 0 16px; }
          .brand-mark { height: 28px; }
          .brand-title { font-size: 12px; }
          .brand-subtitle { font-size: 10px; }
          .progress-track { top: 58px; }
          .layout { padding: 76px 0 24px; }
          .report { border: 0; border-radius: 0; box-shadow: none; }
          .hero { padding: 38px 22px 32px; border-bottom-width: 5px; }
          .hero h1 { max-width: 100%; margin-bottom: 26px; font-size: 31px; overflow-wrap: anywhere; word-break: break-word; }
          .hero-meta { display: block; }
          .hero-meta p { margin-top: 10px; font-size: 12px; overflow-wrap: anywhere; word-break: break-word; }
          .report-section { padding: 34px 22px 38px; }
          .report-section h2 { font-size: 25px; }
          .report-section h3 { font-size: 19px; }
          .report-section p, .report-section li { overflow-wrap: anywhere; word-break: break-word; }
          .table-wrap { margin-left: -8px; margin-right: -8px; }
        }
        @media print {
          @page { margin: 16mm 14mm; }
          body { background: #fff; }
          .topbar, .progress-track, .rail { display: none !important; }
          .layout { display: block; max-width: none; padding: 0; }
          .report { border: 0; box-shadow: none; }
          .hero { break-after: page; border-radius: 0; }
          .report-section { padding: 28px 0; break-inside: auto; }
          .report-section h2, .report-section h3 { break-after: avoid; }
          .table-wrap, blockquote { break-inside: avoid; }
          a { color: inherit; }
        }
          </style>
        </head>
        <body>
          <header class="topbar">
            <div class="brand">
              <span class="brand-mark" aria-hidden="true"></span>
              <div><div class="brand-title">AGENDAI / AI ANALYSIS</div><div class="brand-subtitle">会小纪智能会议纪要阅读版</div></div>
            </div>
            <div class="topbar-note">\(todoCount) 项任务分工 · 会议 ID \(meetingID)</div>
            <button class="menu-toggle" id="menu-toggle" type="button" aria-label="打开章节导航" aria-expanded="false"><span></span></button>
          </header>
          <div class="progress-track" aria-hidden="true"><div class="progress-value" id="progress-value"></div></div>
          <div class="layout">
            <aside class="rail" aria-label="章节导航">
              <div class="rail-kicker">Analysis index</div>
              <div class="rail-caption">按章节浏览 AI 分析会议纪要</div>
              <nav class="toc" id="toc"></nav>
            </aside>
            <main class="main">
              <article class="report" id="report">
                <header class="hero" id="section-hero">
                  <div class="hero-kicker">AGENDAI / AI ANALYSIS MINUTES</div>
                  <h1>\(title)</h1>
                  <div class="hero-meta">
                    <p>生成时间：\(generatedAt)</p>
                    <p>会议 ID：\(meetingID)</p>
                    <p>任务分工：\(todoCount) 项</p>
                    <p>事实边界：会议资料、人员库与外部分析分层</p>
                  </div>
                </header>
                <section class="report-section" id="section-summary">
                  <h2>综合分析</h2>
                  <blockquote><p><strong>执行摘要：</strong>\(escapeHTML(document.executiveSummary))</p></blockquote>
                </section>
                <section class="report-section" id="section-findings">
                  <h2>分析结论</h2>
                  \(findingHTML)
                </section>
                <section class="report-section" id="section-assignments">
                  <h2>任务分工派发</h2>
                  <p class="document-meta">负责人仅取自人员库启用人员；职责匹配时优先有禅道账号的人员。</p>
                  <div class="table-wrap"><table><thead><tr><th>事项</th><th>负责人</th><th>具体任务</th><th>交付物</th><th>截止时间</th><th>分派依据</th><th>证据</th></tr></thead><tbody>\(todoRows)</tbody></table></div>
                </section>
                <section class="report-section" id="section-risks">
                  <h2>风险与待确认</h2>
                  \(risks)
                </section>
                <section class="report-section" id="section-sources">
                  <h2>分析来源</h2>
                  <ul>\(sources)</ul>
                </section>
              </article>
            </main>
          </div>
          <script>
        (function () {
          const body = document.body;
          const report = document.getElementById('report');
          const toc = document.getElementById('toc');
          const headings = Array.from(report.querySelectorAll('.report-section h2'));
          const sections = headings.map((heading) => heading.parentElement);
          headings.forEach((heading, index) => {
            const link = document.createElement('a');
            link.href = '#' + sections[index].id;
            link.innerHTML = '<span class="toc-index">' + String(index + 1).padStart(2, '0') + '</span><span>' + heading.textContent + '</span>';
            toc.appendChild(link);
          });
          const links = Array.from(toc.querySelectorAll('a'));
          const observer = new IntersectionObserver((entries) => {
            entries.forEach((entry) => {
              if (!entry.isIntersecting) return;
              const index = sections.indexOf(entry.target);
              links.forEach((link, linkIndex) => link.classList.toggle('active', linkIndex === index));
            });
          }, { rootMargin: '-18% 0px -70% 0px', threshold: 0 });
          sections.forEach((section) => observer.observe(section));
          function updateProgress() {
            const scrollable = document.documentElement.scrollHeight - window.innerHeight;
            const progress = scrollable > 0 ? (window.scrollY / scrollable) * 100 : 0;
            document.getElementById('progress-value').style.width = progress + '%';
          }
          window.addEventListener('scroll', updateProgress, { passive: true });
          updateProgress();
          document.getElementById('menu-toggle').addEventListener('click', function () {
            body.classList.toggle('nav-open');
            this.setAttribute('aria-expanded', body.classList.contains('nav-open') ? 'true' : 'false');
          });
          links.forEach((link) => link.addEventListener('click', () => body.classList.remove('nav-open')));
        })();
          </script>
        </body>
        </html>
        """
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func escapeTable(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func escapeHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
}

enum MeetingAnalysisGenerationError: Error, LocalizedError {
    case emptyResponse
    case invalidStructuredOutput

    var errorDescription: String? {
        switch self {
        case .emptyResponse:
            "Agent 未返回 AI 分析会议纪要。"
        case .invalidStructuredOutput:
            "Agent 返回的 AI 分析会议纪要不是有效结构化内容，请重试。"
        }
    }
}

private extension String {
    var trimmedNonempty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
