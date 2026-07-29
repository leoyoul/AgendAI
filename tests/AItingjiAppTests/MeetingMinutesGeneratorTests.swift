import AItingjiCore
import Foundation
import Testing
@testable import AItingjiApp

@Suite("Meeting minutes generation")
struct MeetingMinutesGeneratorTests {
    @Test("mock generation renders the formal MD and HTML templates and persists them")
    func generateAndReloadFormalMinutes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_784_236_800)
        let generator = MeetingMinutesGenerator(storageDirectory: directory, now: { now })
        let meeting = Meeting(
            id: "meeting-1",
            title: "项目周例会",
            status: .done,
            createdAt: now,
            startedAt: now,
            endedAt: now.addingTimeInterval(25 * 60)
        )
        let segments = [
            TranscriptSegment(
                id: "segment-1",
                meetingID: meeting.id,
                startMs: 0,
                endMs: 3_000,
                speakerLabel: "speaker_1",
                personID: "person-1",
                personName: "李明",
                rawText: "先确认项目进度。"
            )
        ]
        let source = ModelSource(
            id: "minutes-mock",
            type: .meetingMinutes,
            name: "纪要测试模型",
            baseURL: "mock://meeting-minutes",
            selectedModel: "mock",
            isDefault: true,
            enabled: true
        )

        let artifact = try await generator.generate(meeting: meeting, segments: segments, source: source)

        #expect(artifact.document.participants == ["李明"])
        #expect(artifact.document.duration == "约25分钟")
        #expect(artifact.markdown.contains("## 一、会议基本信息"))
        #expect(artifact.markdown.contains("## 三、会议主要内容"))
        #expect(artifact.markdown.contains("| 序号 | 主要内容要点 | 详细说明 |"))
        #expect(artifact.markdown.contains("## 八、归档清单"))
        #expect(artifact.markdown.contains("| 序号 | 行动项 | 责任人 | 时间要求 |"))
        #expect(artifact.html.contains("<!DOCTYPE html>"))
        #expect(artifact.html.contains("会议主要内容"))
        #expect(artifact.html.contains("<th>主要内容要点</th>"))
        #expect(artifact.html.contains("@media print"))
        #expect(artifact.html.contains("@media (max-width: 720px)"))
        #expect(artifact.html.contains("项目周例会会议纪要"))

        try FileManager.default.removeItem(at: directory.appendingPathComponent("meeting-1.md"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("meeting-1.html"))
        let loaded = try generator.load(meetingID: meeting.id)
        let reloaded = try #require(loaded)
        #expect(reloaded == artifact)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting-1.md").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting-1.html").path))
        #expect(MeetingMinutesGenerator.exportFileName(document: artifact.document, pathExtension: "html") == "项目周例会-20260717-会议纪要.html")
    }

    @Test("loading preserves existing MD and HTML artifacts")
    func loadingPreservesExistingDerivedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-preserve-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generator = MeetingMinutesGenerator(storageDirectory: directory)
        let meeting = Meeting(
            id: "meeting-preserve",
            title: "保留已有纪要",
            status: .done,
            createdAt: Date()
        )
        let source = ModelSource(
            id: "minutes-preserve",
            type: .meetingMinutes,
            name: "纪要测试模型",
            baseURL: "mock://meeting-minutes",
            selectedModel: "mock",
            isDefault: true,
            enabled: true
        )
        _ = try await generator.generate(
            meeting: meeting,
            segments: [TranscriptSegment(
                id: "segment-preserve",
                meetingID: meeting.id,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "speaker_1",
                rawText: "保留已有纪要文件。"
            )],
            source: source
        )
        let markdown = "# 已有 Markdown 纪要\n"
        let html = "<!DOCTYPE html><html><body>已有 HTML 纪要</body></html>"
        try markdown.write(
            to: directory.appendingPathComponent("meeting-preserve.md"),
            atomically: true,
            encoding: .utf8
        )
        try html.write(
            to: directory.appendingPathComponent("meeting-preserve.html"),
            atomically: true,
            encoding: .utf8
        )

        let cached = try generator.load(meetingID: meeting.id)
        let loaded = try #require(cached)

        #expect(loaded.markdown == markdown)
        #expect(loaded.html == html)
    }

    @Test("renderer escapes HTML and Markdown table content")
    func rendererEscapesUntrustedContent() {
        let document = fixtureDocument(
            summary: #"需要确认 <script>alert("x")</script> & 后续安排"#,
            conclusion: "A | B"
        )

        let markdown = MeetingMinutesRenderer.markdown(document)
        let html = MeetingMinutesRenderer.html(document)

        #expect(markdown.contains("A \\| B"))
        #expect(html.contains("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; 后续安排"))
        #expect(!html.contains(#"<script>alert("x")</script>"#))
    }

    @Test("legacy cached minutes without main topics still load")
    func loadsLegacyCacheWithoutMainTopics() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-legacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = fixtureDocument(summary: "旧纪要摘要仍应作为主要内容显示。", conclusion: "继续执行。")
        let encoded = try JSONEncoder().encode(document)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "mainTopics")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        try legacyData.write(to: directory.appendingPathComponent("meeting-fixture.json"))

        let cached = try MeetingMinutesGenerator(storageDirectory: directory).load(meetingID: document.meetingID)
        let loaded = try #require(cached)

        #expect(loaded.document.mainTopics == nil)
        #expect(loaded.markdown.contains("## 三、会议主要内容"))
        #expect(loaded.markdown.contains("旧纪要摘要仍应作为主要内容显示。"))
        #expect(loaded.markdown.contains("| 序号 | 主要内容要点 | 详细说明 |"))
        #expect(!loaded.markdown.contains("## 四、议题讨论还原"))
    }

    @Test("high-fidelity document survives cache round-trip and old topic objects remain decodable")
    func highFidelityDocumentRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-round-trip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var document = fixtureDocument(summary: "高保真摘要。", conclusion: "形成方向。")
        document.meetingType = "方案研讨"
        document.backgroundAndPurpose = "确认边界。"
        document.expectedProblem = "形成初稿。"
        document.participantDetails = [MeetingMinutesParticipant(name: "王总", role: "技防", evidence: "00:01", status: "待确认")]
        document.keyFacts = [MeetingMinutesKeyFact(item: "周期", value: "五年", nature: "项目事实", context: "项目", evidence: "00:02")]
        document.mainTopics = [MeetingMinutesMainTopic(
            topic: "高保真议题",
            details: "讨论",
            timeRange: "00:01-00:03",
            question: "问题",
            viewpoints: [MeetingMinutesViewpoint(speaker: "王总", viewpoint: "观点", basis: "依据", evidence: "00:02")],
            discussionSteps: [MeetingMinutesDiscussionStep(kind: "回应", speaker: "王总", content: "回应", timeRange: "00:02", evidence: "00:02")],
            discussionProcess: "推进",
            outcome: "方向",
            status: "暂定方向",
            evidence: "00:01-00:03"
        )]
        document.conclusions = [MeetingMinutesConclusion(topic: "事项", conclusion: "结论", status: "暂定方向", rationale: "依据", scope: "范围", evidence: "00:03")]
        document.actions = [MeetingMinutesAction(action: "行动", owners: ["待确认"], deadline: "下周", deliverable: "初稿", dependencies: ["资料"], acceptanceCriteria: "覆盖范围", status: "待确认", evidence: "00:04")]
        document.risks = [MeetingMinutesRisk(risk: "风险", impact: "影响", mitigation: "处理", category: "开放问题", nextStep: "核实", evidence: "00:05")]

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let cacheURL = directory.appendingPathComponent("meeting-fixture.json")
        try encoder.encode(document).write(to: cacheURL)

        let generator = MeetingMinutesGenerator(storageDirectory: directory)
        let loaded = try #require(try generator.load(meetingID: document.meetingID))
        #expect(loaded.document.participantDetails?.first?.role == "技防")
        #expect(loaded.document.keyFacts?.first?.value == "五年")
        #expect(loaded.document.mainTopics?.first?.discussionSteps?.first?.kind == "回应")
        #expect(loaded.document.conclusions.first?.rationale == "依据")
        #expect(loaded.document.actions.first?.dependencies == ["资料"])
        #expect(loaded.document.risks.first?.evidence == "00:05")

        var object = try #require(JSONSerialization.jsonObject(with: try JSONEncoder().encode(document)) as? [String: Any])
        object.removeValue(forKey: "participantDetails")
        object.removeValue(forKey: "meetingType")
        object.removeValue(forKey: "backgroundAndPurpose")
        object.removeValue(forKey: "expectedProblem")
        object.removeValue(forKey: "keyFacts")
        if var topics = object["mainTopics"] as? [[String: Any]], var topic = topics.first {
            for key in ["timeRange", "question", "viewpoints", "discussionSteps", "discussionProcess", "outcome", "status", "evidence"] {
                topic.removeValue(forKey: key)
            }
            topics[0] = topic
            object["mainTopics"] = topics
        }
        try JSONSerialization.data(withJSONObject: object).write(to: cacheURL)
        let legacy = try #require(try MeetingMinutesGenerator(storageDirectory: directory).load(meetingID: document.meetingID))
        #expect(legacy.document.mainTopics?.first?.discussionSteps == nil)
    }

    @Test("vocabulary normalization keeps high-fidelity fields")
    func normalizesHighFidelityFields() {
        let vocabulary = MeetingMinutesVocabulary(
            terminologyEntries: [TerminologyEntry(id: "term", canonicalName: "示例科技", aliases: ["示例"])],
            people: [VoiceprintPerson(id: "person", displayName: "尤磊", aliases: ["王总"])]
        )
        let draft = MeetingMinutesModelDraft(
            meetingTitle: "示例方案",
            meetingType: "方案研讨",
            backgroundAndPurpose: "王总介绍示例",
            expectedProblem: "形成示例初稿",
            participants: [MeetingMinutesParticipant(name: "王总", role: "示例负责人", evidence: "王总发言", status: "待确认")],
            subtitle: "示例",
            summary: "王总讨论示例。",
            mainTopics: [MeetingMinutesMainTopic(
                topic: "示例议题",
                details: "王总提出",
                viewpoints: [MeetingMinutesViewpoint(speaker: "王总", viewpoint: "示例方向", basis: "王总说明", evidence: "00:01")],
                discussionSteps: [MeetingMinutesDiscussionStep(kind: "提问", speaker: "王总", content: "示例怎么做", timeRange: "00:01", evidence: "00:01")],
                outcome: "示例继续",
                status: "暂定方向",
                evidence: "00:01"
            )],
            keyFacts: [MeetingMinutesKeyFact(item: "名称", value: "示例", nature: "项目事实", context: "王总说明", evidence: "00:01")],
            conclusions: [MeetingMinutesConclusion(topic: "示例", conclusion: "王总继续", rationale: "王总依据", evidence: "00:01")],
            actions: [MeetingMinutesAction(action: "示例行动", owners: ["王总"], deadline: "待确认", deliverable: "示例初稿", dependencies: ["示例资料"], acceptanceCriteria: "王总确认", evidence: "00:01")],
            risks: [MeetingMinutesRisk(risk: "示例风险", impact: "示例影响", mitigation: "王总处理", category: "开放问题", nextStep: "核实示例", evidence: "00:01")],
            milestones: [],
            archiveItems: ["示例资料"]
        )

        let normalized = vocabulary.normalize(draft)
        #expect(normalized.participants?.first?.name == "尤磊")
        #expect(normalized.mainTopics?.first?.discussionSteps?.first?.speaker == "尤磊")
        #expect(normalized.keyFacts?.first?.value == "示例科技")
        #expect(normalized.actions.first?.owners == ["尤磊"])
        #expect(normalized.risks.first?.nextStep == "核实示例科技")
    }

    @Test("structured model response accepts a fenced JSON object")
    func decodeStructuredResponse() throws {
        let response = """
        ```json
        {
          "meeting_title": "现场部署方案确认",
          "subtitle": "现场条件与交付安排",
          "summary": "确认现场条件后再冻结方案。",
          "main_topics": [{"topic": "现场条件", "details": "讨论了网络、电源和安装空间，需核实后冻结方案。"}],
          "conclusions": [{"topic": "部署", "conclusion": "部署方式待确认。"}],
          "actions": [{"action": "核实网络", "owners": ["刘瑜"], "deadline": "2026年7月17日"}],
          "risks": [],
          "milestones": [{"date": "2026年7月17日", "target": "完成现场确认"}],
          "archive_items": ["实施方案"]
        }
        ```
        """

        let draft = try MeetingMinutesGenerator.decodeDraft(response)

        #expect(draft.subtitle == "现场条件与交付安排")
        #expect(draft.meetingTitle == "现场部署方案确认")
        #expect(draft.mainTopics?.first?.topic == "现场条件")
        #expect(draft.actions.first?.owners == ["刘瑜"])
        #expect(draft.archiveItems == ["实施方案"])
    }

    @Test("structured model response accepts high-fidelity discussion fields")
    func decodeHighFidelityStructuredResponse() throws {
        let response = """
        {
          "meeting_title": "建设期事故预防服务方案研讨",
          "meeting_type": "方案研讨",
          "subtitle": "施工阶段服务方向与成本安排",
          "summary": "确认建设期事故预防服务方向，并梳理后续方案和资料。",
          "background_and_purpose": "确认建设期事故预防服务方向。",
          "expected_problem": "形成施工阶段服务方案初稿并明确资料缺口。",
          "participants": [{"name":"王总","role":"技防负责人","evidence":"00:04:10 明确介绍","status":"待确认"}],
          "main_topics": [{
            "topic":"保险阶段与监测对象",
            "details":"围绕施工期与运营期的监测对象展开。",
            "time_range":"00:01:20-00:02:50",
            "question":"当前保险覆盖施工阶段还是运营阶段？",
            "viewpoints":[{"speaker":"王总","viewpoint":"施工期应关注人员和施工安全。","basis":"不同阶段监测对象不同。","evidence":"00:02:20-00:02:40"}],
            "discussion_steps":[{"kind":"提问","speaker":"王总","content":"先确认保险阶段。","time_range":"00:01:20-00:01:40","evidence":"00:01:20-00:01:40"}],
            "discussion_process":"先提出阶段疑问，查阅文件后倾向施工阶段。",
            "outcome":"按建设施工阶段继续设计。",
            "status":"暂定方向",
            "evidence":"00:01:20-00:02:50"
          }],
          "key_facts": [{"item":"项目周期","value":"五年","nature":"项目事实","context":"独库项目","evidence":"00:07:30-00:07:40"}],
          "conclusions": [{"topic":"服务阶段","conclusion":"按建设施工阶段设计。","status":"暂定方向","rationale":"依据当前文件和现场说明。","scope":"本次方案初稿","evidence":"00:05:20-00:06:40"}],
          "actions": [{"action":"形成方案初稿","owners":["待确认"],"deadline":"下周","deliverable":"方案初稿","dependencies":["招标文件"],"acceptance_criteria":"覆盖技防、人防和基础服务","status":"待确认","evidence":"00:11:10-00:11:30"}],
          "risks": [{"category":"待核实事实","risk":"保单范围尚未完整确认。","impact":"可能影响方案边界。","mitigation":"核对正式文件。","next_step":"取得完整保单","evidence":"00:11:30-00:12:10"}],
          "milestones": [],
          "archive_items": ["招标文件"]
        }
        """

        let draft = try MeetingMinutesGenerator.decodeDraft(response)

        #expect(draft.meetingType == "方案研讨")
        #expect(draft.expectedProblem == "形成施工阶段服务方案初稿并明确资料缺口。")
        #expect(draft.participants?.first?.role == "技防负责人")
        #expect(draft.mainTopics?.first?.discussionSteps?.first?.kind == "提问")
        #expect(draft.keyFacts?.first?.nature == "项目事实")
        #expect(draft.conclusions.first?.status == "暂定方向")
        #expect(draft.actions.first?.acceptanceCriteria == "覆盖技防、人防和基础服务")
        #expect(draft.risks.first?.category == "待核实事实")
    }

    @Test("formal minutes prompt requires concise grouped discussion")
    func formalMinutesPromptContract() {
        let prompt = PostprocessPrompt.meetingMinutes

        #expect(prompt.contains("简洁、正式、便于内部流转"))
        #expect(prompt.contains("按少量核心议题归并"))
        #expect(prompt.contains("discussion_steps"))
        #expect(prompt.contains("expected_problem"))
        #expect(prompt.contains("key_facts"))
        #expect(prompt.contains("简短时间范围"))
        #expect(!prompt.contains("宁可提取更多具体要点"))
        #expect(!prompt.contains("details 只写 1 至 3 句、不超过 180 个中文字"))
        #expect(!prompt.contains("知识库搜索"))
        #expect(!prompt.contains("竞品分析"))
    }

    @Test("high-fidelity markdown renders the discussion record")
    func rendersHighFidelityMarkdown() {
        var document = fixtureDocument(summary: "需要确认会议方向。", conclusion: "形成初步方向。")
        document.meetingType = "方案研讨"
        document.backgroundAndPurpose = "确认方案边界。"
        document.expectedProblem = "形成下一步初稿。"
        document.participantDetails = [
            MeetingMinutesParticipant(name: "王总", role: "技防负责人", evidence: "00:04:10 明确介绍", status: "待确认")
        ]
        document.keyFacts = [
            MeetingMinutesKeyFact(item: "项目周期", value: "五年", nature: "项目事实", context: "独库项目", evidence: "00:07:30-00:07:40")
        ]
        document.mainTopics = [
            MeetingMinutesMainTopic(
                topic: "保险阶段与监测对象",
                details: "围绕施工期与运营期的监测对象展开。",
                timeRange: "00:01:20-00:02:50",
                question: "当前保险覆盖施工阶段还是运营阶段？",
                viewpoints: [MeetingMinutesViewpoint(speaker: "王总", viewpoint: "施工期关注人员和施工安全。", basis: "阶段不同，监测对象不同。", evidence: "00:02:20-00:02:40")],
                discussionSteps: [MeetingMinutesDiscussionStep(kind: "提问", speaker: "王总", content: "先确认保险阶段。", timeRange: "00:01:20-00:01:40", evidence: "00:01:20-00:01:40")],
                discussionProcess: "先提出阶段疑问，再依据文件形成方向。",
                outcome: "按建设施工阶段继续设计。",
                status: "暂定方向",
                evidence: "00:01:20-00:02:50"
            )
        ]
        document.conclusions = [MeetingMinutesConclusion(topic: "服务阶段", conclusion: "按建设施工阶段设计。", status: "暂定方向", rationale: "依据当前文件和现场说明。", scope: "本次方案初稿", evidence: "00:05:20-00:06:40")]
        document.actions = [MeetingMinutesAction(action: "形成方案初稿", owners: ["待确认"], deadline: "下周", deliverable: "方案初稿", dependencies: ["招标文件"], acceptanceCriteria: "覆盖技防、人防和基础服务", status: "待确认", evidence: "00:11:10-00:11:30")]
        document.risks = [MeetingMinutesRisk(risk: "保单范围尚未完整确认。", impact: "可能影响方案边界。", mitigation: "核对正式文件。", category: "待核实事实", nextStep: "取得完整保单", evidence: "00:11:30-00:12:10")]

        let markdown = MeetingMinutesRenderer.markdown(document)

        #expect(markdown.contains("## 一、会议摘要"))
        #expect(markdown.contains("## 二、讨论纪要"))
        #expect(markdown.contains("## 三、会议结论与待确认事项"))
        #expect(markdown.contains("## 四、后续行动"))
        #expect(markdown.contains("00:01:20-00:02:50"))
        #expect(markdown.contains("主要意见"))
        #expect(markdown.contains("形成结果"))
        #expect(markdown.contains("状态：暂定方向"))
        #expect(markdown.contains("交付物"))
        #expect(markdown.contains("保单范围尚未完整确认"))
        #expect(markdown.contains("核对正式文件；取得完整保单"))
        #expect(!markdown.contains("。；"))
        #expect(!markdown.contains("## 五、关键事实与数字"))
    }

    @Test("high-fidelity HTML renders semantic discussion blocks without horizontal overflow tables")
    func rendersHighFidelityHTML() {
        var document = fixtureDocument(summary: "需要确认会议方向。", conclusion: "形成初步方向。")
        document.backgroundAndPurpose = "确认方案边界。"
        document.expectedProblem = "形成下一步初稿。"
        document.mainTopics = [MeetingMinutesMainTopic(
            topic: "议题 <一>",
            details: "讨论过程。",
            timeRange: "00:01:20-00:02:50",
            question: "问题 & 约束",
            viewpoints: [MeetingMinutesViewpoint(speaker: "发言人", viewpoint: "观点", basis: "依据", evidence: "00:01:30")],
            discussionSteps: [MeetingMinutesDiscussionStep(kind: "回应", speaker: "发言人", content: "回应内容", timeRange: "00:01:40", evidence: "00:01:40")],
            discussionProcess: "先问后答。",
            outcome: "暂定方向",
            status: "暂定方向",
            evidence: "00:01:20-00:02:50"
        )]

        let html = MeetingMinutesRenderer.html(document)

        #expect(html.contains("二、讨论纪要"))
        #expect(html.contains("class=\"topic\""))
        #expect(html.contains("00:01:20-00:02:50"))
        #expect(html.contains("&lt;一&gt;"))
        #expect(html.contains("&amp; 约束"))
        #expect(html.contains("@media (max-width:640px)"))
        #expect(html.contains("max-width:860px"))
        #expect(!html.contains("box-shadow"))
        #expect(!html.contains("discussion-topic"))
    }

    @Test("writes high-fidelity HTML preview when requested")
    func writeHighFidelityHTMLPreview() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["TINGLAN_HTML_PREVIEW_OUTPUT"], !outputPath.isEmpty else {
            return
        }
        var document = fixtureDocument(summary: "预览摘要。", conclusion: "预览方向。")
        document.meetingType = "方案研讨"
        document.backgroundAndPurpose = "预览背景。"
        document.expectedProblem = "预览问题。"
        document.mainTopics = [MeetingMinutesMainTopic(
            topic: "预览议题",
            details: "预览讨论。",
            timeRange: "00:01-00:02",
            question: "预览问题",
            discussionSteps: [MeetingMinutesDiscussionStep(kind: "提问", speaker: "待确认", content: "预览步骤。", timeRange: "00:01", evidence: "00:01")],
            outcome: "预览方向",
            status: "暂定方向",
            evidence: "00:01-00:02"
        )]
        try FileManager.default.createDirectory(atPath: outputPath, withIntermediateDirectories: true)
        try MeetingMinutesRenderer.html(document).write(
            to: URL(fileURLWithPath: outputPath).appendingPathComponent("high-fidelity-preview.html"),
            atomically: true,
            encoding: .utf8
        )
    }

    @Test("invalid model response is rejected")
    func rejectInvalidStructuredResponse() {
        #expect(throws: MeetingMinutesGenerationError.self) {
            try MeetingMinutesGenerator.decodeDraft("这不是结构化内容")
        }
    }

    @Test("structured model response normalizes scalar nested fields")
    func normalizesScalarNestedFields() throws {
        let response = """
        {
          "meeting_title": "字段诊断",
          "subtitle": "诊断",
          "summary": "检查错误字段。",
          "main_topics": [{
            "topic": "结构兼容",
            "viewpoints": ["张三认为应保留原始事实。"],
            "discussion_steps": ["团队随后确认处理方式。"],
            "outcome": "按兼容方式处理。"
          }],
          "conclusions": ["采用兼容解析。"],
          "actions": [{"action": "整理材料", "owners": "张三", "deadline": "待确认", "dependencies": "原始转写"}],
          "risks": ["模型偶尔省略嵌套字段。"],
          "milestones": ["完成修复"],
          "archive_items": []
        }
        """

        let draft = try MeetingMinutesGenerator.decodeDraft(response)

        #expect(draft.mainTopics?.first?.details == "按兼容方式处理。")
        #expect(draft.mainTopics?.first?.viewpoints?.first?.speaker == "待确认")
        #expect(draft.mainTopics?.first?.viewpoints?.first?.viewpoint == "张三认为应保留原始事实。")
        #expect(draft.mainTopics?.first?.viewpoints?.first?.basis == "待确认")
        #expect(draft.mainTopics?.first?.viewpoints?.first?.evidence == nil)
        #expect(draft.mainTopics?.first?.discussionSteps?.first?.kind == "讨论")
        #expect(draft.mainTopics?.first?.discussionSteps?.first?.speaker == "待确认")
        #expect(draft.mainTopics?.first?.discussionSteps?.first?.content == "团队随后确认处理方式。")
        #expect(draft.actions.first?.owners == ["张三"])
        #expect(draft.actions.first?.dependencies == ["原始转写"])
        #expect(draft.conclusions.first?.conclusion == "采用兼容解析。")
        #expect(draft.risks.first?.risk == "模型偶尔省略嵌套字段。")
        #expect(draft.milestones.first?.target == "完成修复")
    }

    @Test("structured model response fills a missing topic details field")
    func fillsMissingTopicDetails() throws {
        let response = """
        {
          "subtitle": "字段兼容",
          "summary": "检查缺失字段。",
          "main_topics": [{"topic": "缺少详情", "question": "如何兼容？"}],
          "conclusions": [],
          "actions": [],
          "risks": [],
          "milestones": [],
          "archive_items": []
        }
        """

        let draft = try MeetingMinutesGenerator.decodeDraft(response)

        #expect(draft.mainTopics?.first?.details == "如何兼容？")
    }

    @Test("configured system prompt is sent with one-time instructions")
    func configuredPromptIsSentToModel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-custom-prompt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = MeetingMinutesPromptProbe()
        let generator = MeetingMinutesGenerator(
            storageDirectory: directory,
            modelResponseGenerator: { _, systemPrompt, _ in
                await probe.respond(to: systemPrompt)
            }
        )
        let source = ModelSource(
            id: "minutes-custom-prompt",
            type: .meetingMinutes,
            name: "自定义提示词模型",
            baseURL: "http://127.0.0.1:18001/v1",
            selectedModel: "test-model",
            isDefault: true,
            enabled: true
        )
        let meeting = Meeting(id: "meeting-custom-prompt", title: "提示词测试", status: .done, createdAt: Date())
        let segments = [
            TranscriptSegment(
                id: "segment-custom-prompt",
                meetingID: meeting.id,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "speaker_1",
                rawText: "测试自定义提示词。"
            )
        ]

        _ = try await generator.generate(
            meeting: meeting,
            segments: segments,
            source: source,
            prompt: "自定义系统提示词",
            additionalPrompt: "本次保留技术细节"
        )

        let receivedPrompt = await probe.lastPrompt
        #expect(receivedPrompt?.hasPrefix("自定义系统提示词") == true)
        #expect(receivedPrompt?.contains("本次保留技术细节") == true)
        #expect(receivedPrompt?.contains("你是严谨的中文会议纪要整理助手") == false)
    }

    @Test("different meetings are queued and reach the selected model one at a time")
    func differentMeetingsGenerateSerially() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-concurrency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = MeetingMinutesConcurrencyProbe()
        let generator = MeetingMinutesGenerator(
            storageDirectory: directory,
            modelResponseGenerator: { _, _, _ in
                try await probe.respond()
            }
        )
        let source = ModelSource(
            id: "minutes-concurrency",
            type: .meetingMinutes,
            name: "并发纪要模型",
            baseURL: "http://127.0.0.1:18001/v1",
            selectedModel: "new-model",
            isDefault: true,
            enabled: true
        )
        let firstMeeting = Meeting(
            id: "meeting-concurrency-1",
            title: "并发会议一",
            status: .done,
            createdAt: Date()
        )
        let secondMeeting = Meeting(
            id: "meeting-concurrency-2",
            title: "并发会议二",
            status: .done,
            createdAt: Date()
        )
        let firstSegments = [
            TranscriptSegment(
                id: "segment-concurrency-1",
                meetingID: firstMeeting.id,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "speaker_1",
                rawText: "会议一。"
            )
        ]
        let secondSegments = [
            TranscriptSegment(
                id: "segment-concurrency-2",
                meetingID: secondMeeting.id,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "speaker_1",
                rawText: "会议二。"
            )
        ]

        async let firstArtifact = generator.generate(
            meeting: firstMeeting,
            segments: firstSegments,
            source: source
        )
        async let secondArtifact = generator.generate(
            meeting: secondMeeting,
            segments: secondSegments,
            source: source
        )
        _ = try await (firstArtifact, secondArtifact)

        #expect(await probe.maximumActiveRequests == 1)
    }

    @Test("configured meeting minutes concurrency allows two model requests")
    func configuredConcurrencyAllowsTwoRequests() async throws {
        #expect(try await observedMaximumConcurrency(configuredMaximumConcurrency: 2) == 2)
    }

    @Test("unlimited meeting minutes concurrency does not queue model requests")
    func unlimitedConcurrencyDoesNotQueueRequests() async throws {
        #expect(try await observedMaximumConcurrency(configuredMaximumConcurrency: nil) == 3)
    }

    private func observedMaximumConcurrency(
        configuredMaximumConcurrency: Int?
    ) async throws -> Int {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-configured-concurrency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = MeetingMinutesConcurrencyProbe()
        let generator = MeetingMinutesGenerator(
            storageDirectory: directory,
            modelResponseGenerator: { _, _, _ in
                try await probe.respond()
            }
        )
        let source = ModelSource(
            id: "minutes-configured-concurrency",
            type: .meetingMinutes,
            name: "可配置并发纪要模型",
            baseURL: "https://example.test/v1",
            selectedModel: "cloud-model",
            isDefault: true,
            enabled: true,
            meetingMinutesMaximumConcurrency: configuredMaximumConcurrency
        )

        try await withThrowingTaskGroup(of: MeetingMinutesArtifact.self) { group in
            for index in 0..<3 {
                let meeting = Meeting(
                    id: "meeting-configured-concurrency-\(index)",
                    title: "并发会议 \(index)",
                    status: .done,
                    createdAt: Date()
                )
                let segments = [TranscriptSegment(
                    id: "segment-configured-concurrency-\(index)",
                    meetingID: meeting.id,
                    startMs: 0,
                    endMs: 1_000,
                    speakerLabel: "speaker_1",
                    rawText: "会议 \(index)。"
                )]
                group.addTask {
                    try await generator.generate(
                        meeting: meeting,
                        segments: segments,
                        source: source
                    )
                }
            }
            for try await _ in group {}
        }
        return await probe.maximumActiveRequests
    }

    @Test("main topic suggestion scales conservatively without forcing expansion")
    func scalesMainTopicsWithoutForcedExpansion() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-coverage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = MeetingMinutesCoverageProbe()
        let generator = MeetingMinutesGenerator(
            storageDirectory: directory,
            modelResponseGenerator: { _, systemPrompt, userText in
                try await probe.respond(systemPrompt: systemPrompt, userText: userText)
            }
        )
        let startedAt = Date(timeIntervalSince1970: 1_784_236_800)
        let longMeeting = Meeting(
            id: "meeting-coverage-90",
            title: "九十分钟项目会议",
            status: .done,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(90 * 60)
        )
        let shortMeeting = Meeting(
            id: "meeting-coverage-15",
            title: "十五分钟项目会议",
            status: .done,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(15 * 60)
        )
        let segments = [
            TranscriptSegment(
                id: "segment-coverage",
                meetingID: longMeeting.id,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "speaker_1",
                rawText: "完整讨论了项目背景、方案、约束、风险和后续安排。"
            )
        ]
        let source = ModelSource(
            id: "minutes-coverage",
            type: .meetingMinutes,
            name: "覆盖测试模型",
            baseURL: "http://127.0.0.1:18001/v1",
            selectedModel: "test-model",
            isDefault: true,
            enabled: true
        )

        #expect(MeetingMinutesGenerator.recommendedMainTopicCount(meeting: shortMeeting, transcript: "测试") == 3)
        #expect(MeetingMinutesGenerator.recommendedMainTopicCount(meeting: longMeeting, transcript: "测试") == 8)

        let artifact = try await generator.generate(
            meeting: longMeeting,
            segments: segments,
            source: source
        )

        #expect(await probe.requestCount == 1)
        #expect(artifact.document.mainTopics?.count == 2)
        #expect(await probe.userTexts.first?.contains("核心议题篇幅建议：约 8 项") == true)
        #expect(await probe.userTexts.first?.contains("这不是最低数量") == true)
    }

    @Test("discussion coverage does not force verbose regeneration")
    func discussionCoverageDoesNotForceRegeneration() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-discussion-coverage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = MeetingMinutesDiscussionCoverageProbe()
        let generator = MeetingMinutesGenerator(
            storageDirectory: directory,
            modelResponseGenerator: { _, systemPrompt, userText in
                try await probe.respond(systemPrompt: systemPrompt, userText: userText)
            }
        )
        let startedAt = Date(timeIntervalSince1970: 1_784_236_800)
        let meeting = Meeting(
            id: "meeting-discussion-coverage",
            title: "讨论覆盖测试",
            status: .done,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(15 * 60)
        )
        let source = ModelSource(
            id: "minutes-discussion-coverage",
            type: .meetingMinutes,
            name: "讨论覆盖测试模型",
            baseURL: "http://127.0.0.1:18001/v1",
            selectedModel: "test-model"
        )

        let artifact = try await generator.generate(
            meeting: meeting,
            segments: [TranscriptSegment(id: "discussion-segment", meetingID: meeting.id, startMs: 0, endMs: 1_000, speakerLabel: "speaker_1", rawText: "完整讨论五个议题。")],
            source: source
        )

        #expect(await probe.requestCount == 1)
        #expect(artifact.document.mainTopics?.count == 5)
        #expect(artifact.document.mainTopics?.filter { !($0.discussionSteps ?? []).isEmpty }.count == 0)
    }

    @Test("truncated structured output is retried before failing")
    func retriesTruncatedStructuredOutput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-truncated-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = MeetingMinutesTruncatedOutputProbe()
        let generator = MeetingMinutesGenerator(
            storageDirectory: directory,
            modelResponseGenerator: { _, systemPrompt, _ in
                try await probe.respond(systemPrompt: systemPrompt)
            }
        )
        let startedAt = Date(timeIntervalSince1970: 1_784_236_800)
        let meeting = Meeting(
            id: "meeting-truncated-output",
            title: "截断输出测试",
            status: .done,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(15 * 60)
        )
        let segments = [
            TranscriptSegment(
                id: "segment-truncated-output",
                meetingID: meeting.id,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "speaker_1",
                rawText: "会议包含五项有效内容。"
            )
        ]
        let source = ModelSource(
            id: "minutes-truncated-output",
            type: .meetingMinutes,
            name: "截断重试模型",
            baseURL: "http://127.0.0.1:18001/v1",
            selectedModel: "test-model",
            isDefault: true,
            enabled: true
        )

        let artifact = try await generator.generate(meeting: meeting, segments: segments, source: source)

        #expect(await probe.requestCount == 2)
        #expect(await probe.systemPrompts.last?.contains("上一版输出被截断") == true)
        #expect(await probe.systemPrompts.last?.contains("discussion_steps") == true)
        #expect(artifact.document.mainTopics?.count == 5)
    }

    @Test("虚构的新同事责任人会改为待确认")
    func sanitizesGeneratedPlaceholderOwners() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-placeholder-owner-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let generator = MeetingMinutesGenerator(
            storageDirectory: directory,
            modelResponseGenerator: { _, _, _ in
                let draft = MeetingMinutesModelDraft(
                    meetingTitle: "责任人测试",
                    subtitle: "测试",
                    summary: "测试摘要。",
                    mainTopics: (1...3).map { MeetingMinutesMainTopic(topic: "要点\($0)", details: "第\($0)项内容。") },
                    conclusions: [],
                    actions: [MeetingMinutesAction(action: "准备申报材料", owners: ["新同事 2"], deadline: "待确认")],
                    risks: [],
                    milestones: [],
                    archiveItems: []
                )
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase
                return String(decoding: try encoder.encode(draft), as: UTF8.self)
            }
        )
        let startedAt = Date(timeIntervalSince1970: 1_784_236_800)
        let meeting = Meeting(
            id: "meeting-placeholder-owner",
            title: "责任人测试",
            status: .done,
            createdAt: startedAt,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60)
        )
        let segment = TranscriptSegment(
            id: "segment-placeholder-owner",
            meetingID: meeting.id,
            startMs: 0,
            endMs: 1_000,
            speakerLabel: "speaker_1",
            rawText: "准备申报材料。"
        )
        let source = ModelSource(
            id: "minutes-placeholder-owner",
            type: .meetingMinutes,
            name: "测试模型",
            baseURL: "http://127.0.0.1:18001/v1",
            selectedModel: "test-model"
        )

        let artifact = try await generator.generate(meeting: meeting, segments: [segment], source: source)

        #expect(artifact.document.actions.first?.owners == ["待确认"])
        #expect(!artifact.markdown.contains("新同事 2"))
    }

    private func fixtureDocument(summary: String, conclusion: String) -> MeetingMinutesDocument {
        MeetingMinutesDocument(
            meetingID: "meeting-fixture",
            title: "测试会议纪要",
            meetingName: "测试会议",
            meetingDate: "2026年7月17日",
            meetingTime: "10:00-10:30",
            duration: "约30分钟",
            participants: ["张三"],
            sources: ["AgendAI 会小纪会议转写记录"],
            subtitle: "测试主题",
            summary: summary,
            mainTopics: [MeetingMinutesMainTopic(topic: "测试议题", details: summary)],
            conclusions: [MeetingMinutesConclusion(topic: "结论", conclusion: conclusion)],
            actions: [],
            risks: [],
            milestones: [],
            archiveItems: ["会议转写"],
            sensitiveNote: "敏感信息单独移交。",
            preparedDate: "2026年7月17日"
        )
    }
}

private actor MeetingMinutesConcurrencyProbe {
    private(set) var maximumActiveRequests = 0
    private var activeRequests = 0

    func respond() async throws -> String {
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        try await Task.sleep(for: .milliseconds(100))
        activeRequests -= 1
        return """
        {
          "meeting_title": "并发生成测试",
          "subtitle": "并发测试",
          "summary": "测试不同会议可以并发生成。",
          "conclusions": [],
          "actions": [],
          "risks": [],
          "milestones": [],
          "archive_items": []
        }
        """
    }
}

private actor MeetingMinutesPromptProbe {
    private(set) var lastPrompt: String?

    func respond(to prompt: String) -> String {
        lastPrompt = prompt
        return """
        {
          "meeting_title": "提示词配置测试",
          "subtitle": "配置测试",
          "summary": "验证自定义系统提示词和单次附加要求会共同发送给模型。",
          "main_topics": [{"topic": "提示词", "details": "模型收到本机保存的系统提示词。"}],
          "conclusions": [],
          "actions": [],
          "risks": [],
          "milestones": [],
          "archive_items": []
        }
        """
    }
}

private actor MeetingMinutesCoverageProbe {
    private(set) var requestCount = 0
    private(set) var systemPrompts: [String] = []
    private(set) var userTexts: [String] = []

    func respond(systemPrompt: String, userText: String) throws -> String {
        requestCount += 1
        systemPrompts.append(systemPrompt)
        userTexts.append(userText)
        let topicCount: Int
        switch requestCount {
        case 1: topicCount = 2
        case 2: topicCount = 16
        default: topicCount = 18
        }
        let draft = MeetingMinutesModelDraft(
            meetingTitle: "长会议覆盖测试",
            subtitle: "完整覆盖会议要点",
            summary: "会议完整讨论了项目背景、方案、约束、风险和后续安排。",
            mainTopics: (1...topicCount).map {
                MeetingMinutesMainTopic(topic: "要点\($0)", details: "第\($0)项独立有效内容。")
            },
            conclusions: [],
            actions: [],
            risks: [],
            milestones: [],
            archiveItems: []
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return String(decoding: try encoder.encode(draft), as: UTF8.self)
    }
}

private actor MeetingMinutesTruncatedOutputProbe {
    private(set) var requestCount = 0
    private(set) var systemPrompts: [String] = []

    func respond(systemPrompt: String) throws -> String {
        requestCount += 1
        systemPrompts.append(systemPrompt)
        if requestCount == 1 {
            return #"{"meeting_title":"未闭合""#
        }
        let draft = MeetingMinutesModelDraft(
            meetingTitle: "截断输出修复",
            subtitle: "结构修复",
            summary: "第二次请求返回完整结构。",
            mainTopics: (1...5).map {
                MeetingMinutesMainTopic(topic: "要点\($0)", details: "完整内容\($0)。")
            },
            conclusions: [],
            actions: [],
            risks: [],
            milestones: [],
            archiveItems: []
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return String(decoding: try encoder.encode(draft), as: UTF8.self)
    }
}

private actor MeetingMinutesDiscussionCoverageProbe {
    private(set) var requestCount = 0

    func respond(systemPrompt: String, userText: String) throws -> String {
        requestCount += 1
        let topics: [MeetingMinutesMainTopic]
        if requestCount == 1 {
            topics = (1...5).map { index in
                if index == 1 {
                    return MeetingMinutesMainTopic(topic: "要点\(index)", details: "有状态但没有讨论步骤。", status: "暂定方向")
                }
                return MeetingMinutesMainTopic(topic: "要点\(index)", details: "没有高保真讨论字段。")
            }
        } else {
            topics = (1...5).map { index in
                MeetingMinutesMainTopic(
                    topic: "要点\(index)",
                    details: "完整讨论内容。",
                    discussionSteps: [MeetingMinutesDiscussionStep(kind: "回应", speaker: "待确认", content: "第\(index)项讨论。", timeRange: "00:0\(index)", evidence: "00:0\(index)")],
                    outcome: "形成方向。",
                    status: "暂定方向",
                    evidence: "00:0\(index)"
                )
            }
        }
        let draft = MeetingMinutesModelDraft(
            meetingTitle: "讨论覆盖测试",
            subtitle: "讨论覆盖",
            summary: "测试高保真议题覆盖重试。",
            mainTopics: topics,
            conclusions: [],
            actions: [],
            risks: [],
            milestones: [],
            archiveItems: []
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return String(decoding: try encoder.encode(draft), as: UTF8.self)
    }
}

@Suite("AppState meeting minutes")
@MainActor
struct AppStateMeetingMinutesTests {
    @Test("meeting minutes prompt can be saved, restored, and reloaded")
    func persistsMeetingMinutesPrompt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: MeetingMinutesTestAPIKeyStore()
        )
        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        #expect(appState.meetingMinutesPrompt == PostprocessPrompt.meetingMinutes)
        appState.updateMeetingMinutesPrompt("自定义会议纪要系统提示词")
        #expect(try store.loadSnapshot().appSettings[AppSettingKey.meetingMinutesPrompt] == "自定义会议纪要系统提示词")

        let reloaded = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR-reloaded"),
            resumePendingTranscriptions: false
        )
        #expect(reloaded.meetingMinutesPrompt == "自定义会议纪要系统提示词")
        reloaded.updateMeetingMinutesPrompt("   ")
        #expect(reloaded.meetingMinutesPrompt == PostprocessPrompt.meetingMinutes)
        #expect(try store.loadSnapshot().appSettings[AppSettingKey.meetingMinutesPrompt] == PostprocessPrompt.meetingMinutes)
    }

    @Test("legacy custom prompt gains coverage rules once without losing edits")
    func upgradesLegacyCustomMeetingMinutesPrompt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-prompt-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: MeetingMinutesTestAPIKeyStore()
        )
        try store.setAppSetting(AppSettingKey.meetingMinutesPrompt, value: "保留我的自定义摘要规则")

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        #expect(appState.meetingMinutesPrompt.hasPrefix("保留我的自定义摘要规则"))
        #expect(appState.meetingMinutesPrompt.contains(PostprocessPrompt.meetingMinutesCoverageRuleMarker))
        let upgradedSnapshot = try store.loadSnapshot()
        #expect(upgradedSnapshot.appSettings[AppSettingKey.meetingMinutesPromptVersion] == PostprocessPrompt.meetingMinutesPromptVersion)

        let reloaded = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR-reloaded"),
            resumePendingTranscriptions: false
        )
        let markerCount = reloaded.meetingMinutesPrompt
            .components(separatedBy: PostprocessPrompt.meetingMinutesCoverageRuleMarker)
            .count - 1
        #expect(markerCount == 1)
    }

    @Test("version 5 prompt with invalid JSON example is migrated on startup")
    func migratesVersion5InvalidJSONPrompt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-prompt-v5-json-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: MeetingMinutesTestAPIKeyStore()
        )
        let legacyPrompt = """
        保留旧版摘要规则。
        {
          "summary": “3-6句话用足够概括的语言完全总结出会议的背景、目标和结论“,
          "archive_items": []
        }
        """
        try store.setAppSetting(AppSettingKey.meetingMinutesPrompt, value: legacyPrompt)
        try store.setAppSetting(AppSettingKey.meetingMinutesPromptVersion, value: "5")

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        #expect(appState.meetingMinutesPrompt.contains(#""summary": "3-6句话用足够概括的语言完全总结出会议的背景、目标和结论","#))
        #expect(!appState.meetingMinutesPrompt.contains(#""summary": “"#))
        let snapshot = try store.loadSnapshot()
        #expect(snapshot.appSettings[AppSettingKey.meetingMinutesPromptVersion] == "7")
        #expect(snapshot.appSettings[AppSettingKey.meetingMinutesPrompt] == appState.meetingMinutesPrompt)
    }

    @Test("legacy meeting minutes prompt replaces managed rules with compact formal rules")
    func replacesLegacyManagedPromptRules() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-minutes-prompt-v4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: MeetingMinutesTestAPIKeyStore()
        )
        try store.setAppSetting(AppSettingKey.meetingMinutesPrompt, value: """
        保留我的项目背景规则。

        【会议主要内容覆盖规则 v2】
        旧版覆盖规则。

        【会议纪要结构与篇幅规则 v3】
        旧版 180 字限制和旧 JSON 规则。
        """)

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        #expect(appState.meetingMinutesPrompt.contains("保留我的项目背景规则"))
        #expect(appState.meetingMinutesPrompt.contains(PostprocessPrompt.meetingMinutesCoverageRuleMarker))
        #expect(appState.meetingMinutesPrompt.contains(PostprocessPrompt.meetingMinutesOutputRuleMarker))
        #expect(!appState.meetingMinutesPrompt.contains("会议主要内容覆盖规则 v2"))
        #expect(!appState.meetingMinutesPrompt.contains("会议纪要结构与篇幅规则 v3"))
        #expect(!appState.meetingMinutesPrompt.contains("旧版 180 字限制"))
        #expect(appState.meetingMinutesPrompt.components(separatedBy: PostprocessPrompt.meetingMinutesCoverageRuleMarker).count - 1 == 1)
    }

    @Test("configuration libraries load even before the first meeting")
    func loadsLibrariesWithoutMeetings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-empty-library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: MeetingMinutesTestAPIKeyStore()
        )
        try store.upsertPerson(VoiceprintPerson(
            id: "person-library",
            displayName: "李明",
            aliases: ["李总", "新同事 2"],
            jobTitle: "产品负责人",
            roleTags: ["产品"],
            zentaoAccount: "liming",
            zentaoUserID: "12"
        ))
        try store.upsertTerminologyEntry(TerminologyEntry(
            id: "term-library",
            canonicalName: "示例科技",
            aliases: ["示例", "新专有名词 1"],
            category: "公司"
        ))

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )

        #expect(appState.meetings.isEmpty)
        #expect(appState.people.first?.zentaoAccount == "liming")
        #expect(appState.people.first?.aliases == ["李总"])
        #expect(appState.terminologyEntries.first?.canonicalName == "示例科技")
        #expect(appState.terminologyEntries.first?.aliases == ["示例"])
        let cleanedSnapshot = try store.loadSnapshot()
        #expect(cleanedSnapshot.people.first?.aliases == ["李总"])
        #expect(cleanedSnapshot.terminologyEntries.first?.aliases == ["示例"])

        var conflicting = TerminologyEntry(
            id: "term-conflict",
            canonicalName: "另一个词",
            aliases: ["李总"]
        )
        #expect(!appState.saveTerminologyEntry(conflicting))
        #expect(appState.libraryStatusMessage.contains("李明"))
        conflicting.aliases = ["另称"]
        #expect(appState.saveTerminologyEntry(conflicting))

        let addedPersonID = try #require(appState.addPerson())
        #expect(appState.people.first?.id == addedPersonID)
        var addedPerson = try #require(appState.people.first(where: { $0.id == addedPersonID }))
        #expect(LibraryPlaceholderPolicy.isGeneratedPersonName(addedPerson.displayName))
        addedPerson.displayName = "吴敏政"
        #expect(appState.savePerson(addedPerson))
        #expect(appState.people.first?.id == addedPersonID)
        let renamedPerson = try #require(appState.people.first(where: { $0.id == addedPersonID }))
        #expect(!renamedPerson.aliases.contains(where: LibraryPlaceholderPolicy.isGeneratedPersonName))

        let addedTermID = try #require(appState.addTerminologyEntry())
        var addedTerm = try #require(appState.terminologyEntries.first(where: { $0.id == addedTermID }))
        #expect(LibraryPlaceholderPolicy.isGeneratedTerminologyName(addedTerm.canonicalName))
        addedTerm.canonicalName = "正式专有名词"
        #expect(appState.saveTerminologyEntry(addedTerm))
        let renamedTerm = try #require(appState.terminologyEntries.first(where: { $0.id == addedTermID }))
        #expect(!renamedTerm.aliases.contains(where: LibraryPlaceholderPolicy.isGeneratedTerminologyName))
    }

    @Test("legacy text model no longer seeds a direct meeting minutes model")
    func doesNotSeedDirectMeetingMinutesModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-seed-minutes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: MeetingMinutesTestAPIKeyStore()
        )
        try store.upsertMeeting(Meeting(id: "seed-meeting", title: "测试会议", createdAt: Date()))
        try store.upsertModelSource(ModelSource(
            id: "existing-text-model",
            type: .postprocess,
            name: "现有文本模型",
            baseURL: "http://127.0.0.1:18001/v1",
            apiKey: "1234",
            selectedModel: "gemma-4-e4b",
            availableModels: ["gemma-4-e4b"],
            isDefault: true,
            enabled: false,
            lastTestOK: true,
            lastTestMessage: "连接成功"
        ))

        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false
        )
        #expect(!appState.modelSources.contains(where: { $0.type == .meetingMinutes }))
        #expect(!appState.hasEnabledMeetingMinutesModel)

        let reloaded = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR-reloaded"),
            resumePendingTranscriptions: false
        )
        #expect(!reloaded.modelSources.contains(where: { $0.type == .meetingMinutes }))
    }

    @Test("AppState uses the Agent model for original minutes and restores the result")
    func generateOriginalMinutesWithAgentModel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinglan-app-minutes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AppPersistenceStore(
            path: directory.appendingPathComponent("test.sqlite").path,
            apiKeyStore: MeetingMinutesTestAPIKeyStore()
        )
        let meeting = Meeting(
            id: "meeting-app-minutes",
            title: "新会议 1",
            status: .done,
            createdAt: Date(),
            startedAt: Date(),
            endedAt: Date().addingTimeInterval(600)
        )
        try store.upsertMeeting(meeting)
        try store.upsertSegment(TranscriptSegment(
            id: "segment-app-minutes",
            meetingID: meeting.id,
            startMs: 0,
            endMs: 2_000,
            speakerLabel: "未分配发言人",
            rawText: "讨论下周交付安排。"
        ))
        try store.upsertModelSource(ModelSource(
            id: "postprocess-only",
            type: .postprocess,
            name: "后处理模型",
            baseURL: "mock://postprocess",
            selectedModel: "mock",
            isDefault: true,
            enabled: true
        ))
        try store.upsertModelSource(ModelSource(
            id: "agent-minutes",
            type: .agent,
            name: "Agent 模型",
            baseURL: "mock://meeting-minutes",
            selectedModel: "mock",
            isDefault: true,
            enabled: true
        ))
        try store.setAppSetting(
            AppSettingKey.pendingPostprocessMeetingIDs,
            value: "[\"\(meeting.id)\"]"
        )
        let storageDirectory = directory.appendingPathComponent("minutes", isDirectory: true)
        let generator = MeetingMinutesGenerator(storageDirectory: storageDirectory)
        let appState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR"),
            resumePendingTranscriptions: false,
            meetingMinutesGenerator: generator
        )
        appState.selectedMeetingID = meeting.id

        #expect(appState.hasEnabledMeetingMinutesModel)
        #expect(appState.canGenerateSelectedMeetingMinutes)
        appState.generateSelectedMeetingMinutes()
        for _ in 0..<100 where appState.generatingMeetingMinutesIDs.contains(meeting.id) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(appState.selectedMeetingMinutesArtifact?.document.meetingID == meeting.id)
        #expect(appState.statusMessage.contains("已生成"))
        let generatedSnapshot = try store.loadSnapshot()
        #expect(generatedSnapshot.meetings.first(where: { $0.id == meeting.id })?.title == "项目进展与后续安排")
        #expect(generatedSnapshot.segmentsByMeeting[meeting.id]?.first?.rawText == "讨论下周交付安排。")
        #expect(generatedSnapshot.appSettings[AppSettingKey.pendingPostprocessMeetingIDs] == "[]")
        let olderMeeting = Meeting(
            id: "meeting-app-minutes-older",
            title: "历史会议",
            status: .done,
            createdAt: meeting.createdAt.addingTimeInterval(-60)
        )
        try store.upsertMeeting(olderMeeting)
        _ = try await generator.generate(
            meeting: olderMeeting,
            segments: [TranscriptSegment(
                id: "segment-app-minutes-older",
                meetingID: olderMeeting.id,
                startMs: 0,
                endMs: 1_000,
                speakerLabel: "未分配发言人",
                rawText: "历史会议纪要。"
            )],
            source: ModelSource(
                id: "minutes-restore",
                type: .meetingMinutes,
                name: "会议纪要模型",
                baseURL: "mock://meeting-minutes",
                selectedModel: "mock",
                isDefault: true,
                enabled: true
            )
        )
        let reloadedAppState = AppState(
            storeFactory: { store },
            pendingTranscriptionRootURL: directory.appendingPathComponent("PendingASR-reloaded"),
            resumePendingTranscriptions: false,
            meetingMinutesGenerator: generator
        )
        reloadedAppState.selectedMeetingID = meeting.id
        #expect(reloadedAppState.selectedMeetingMinutesArtifact?.markdown.contains("## 五、后续行动项") == true)
        #expect(reloadedAppState.meetingMinutesArtifacts[olderMeeting.id]?.document.meetingID == olderMeeting.id)
    }
}

private final class MeetingMinutesTestAPIKeyStore: @unchecked Sendable, ModelSourceAPIKeyStore {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    func apiKey(for reference: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[reference]
    }

    func setAPIKey(_ apiKey: String, for reference: String) throws {
        lock.lock()
        values[reference] = apiKey
        lock.unlock()
    }

    func removeAPIKey(for reference: String) throws {
        lock.lock()
        values.removeValue(forKey: reference)
        lock.unlock()
    }
}
