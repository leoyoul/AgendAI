import Foundation

public enum PostprocessClientError: Error, Equatable, Sendable {
    case missingModel
    case visionModelRequired
    case invalidBaseURL
    case invalidResponseStatus(Int, String)
    case missingContent
}

public protocol PostprocessClient: Sendable {
    func polish(text: String) async throws -> String
}

public struct PostprocessImageInput: Equatable, Sendable {
    public var mimeType: String
    public var data: Data

    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data
    }
}

public struct MockPostprocessClient: PostprocessClient {
    public init() {}

    public func polish(text: String) async throws -> String {
        if text.hasSuffix("。") {
            return text
        }
        return text + "。"
    }
}

public struct OpenAICompatiblePostprocessClient<Uploader: HTTPDataUploading>: PostprocessClient {
    public var source: ModelSource
    public var uploader: Uploader
    public var prompt: String
    public var maxTokens: Int
    public var forceJSONObject: Bool
    public var disableThinking: Bool

    public init(
        source: ModelSource,
        uploader: Uploader,
        prompt: String = PostprocessPrompt.defaultMouthFillerCleanup,
        maxTokens: Int = 4_096,
        forceJSONObject: Bool = false,
        disableThinking: Bool = false
    ) {
        self.source = source
        self.uploader = uploader
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.forceJSONObject = forceJSONObject
        self.disableThinking = disableThinking
    }

    public func polish(text: String) async throws -> String {
        try await complete(
            systemPrompt: prompt,
            userText: text,
            images: []
        )
    }

    public func generateMeetingMinutes(
        systemPrompt: String,
        userText: String
    ) async throws -> String {
        try await complete(
            systemPrompt: systemPrompt,
            userText: userText,
            images: []
        )
    }

    public func generateMeetingMinutes(
        systemPrompt: String,
        userText: String,
        images: [PostprocessImageInput]
    ) async throws -> String {
        try await complete(
            systemPrompt: systemPrompt,
            userText: userText,
            images: images
        )
    }

    private func complete(
        systemPrompt: String,
        userText: String,
        images: [PostprocessImageInput]
    ) async throws -> String {
        guard let model = source.selectedModel, !model.isEmpty else {
            throw PostprocessClientError.missingModel
        }
        if !images.isEmpty && !source.supportsVision {
            throw PostprocessClientError.visionModelRequired
        }
        let endpoint = source.apiProtocol == .responses ? "responses" : "chat/completions"
        guard let url = URL(string: source.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/\(endpoint)") else {
            throw PostprocessClientError.invalidBaseURL
        }

        let body: Data
        switch source.apiProtocol {
        case .chatCompletions:
            let requestBody = ChatCompletionRequest(
                model: model,
                messages: [
                    ChatMessage(
                        role: "system",
                        content: .text(systemPrompt)
                    ),
                    ChatMessage(
                        role: "user",
                        content: .parts(
                            [.text(userText)] + images.map { image in
                                .image(
                                    mimeType: image.mimeType,
                                    data: image.data
                                )
                            }
                        )
                    )
                ],
                temperature: 0,
                maxTokens: maxTokens,
                responseFormat: forceJSONObject ? .jsonObject : nil,
                chatTemplateKwargs: disableThinking ? ["enable_thinking": false] : nil
            )
            body = try JSONEncoder().encode(requestBody)
        case .responses:
            // Responses API 的 JSON 输出约束并非所有兼容服务都支持；严格 JSON
            // 要求已写入 system prompt，避免不兼容的 text.format 导致上游直接断开。
            let requestBody = ResponsesRequest(
                model: model,
                instructions: systemPrompt,
                input: images.isEmpty
                    ? .text(userText)
                    : .parts([.text(userText)] + images.map { image in
                        .image(mimeType: image.mimeType, data: image.data)
                    }),
                maxOutputTokens: maxTokens,
                store: false,
                text: nil
            )
            body = try JSONEncoder().encode(requestBody)
        }
        var headers = ["Content-Type": "application/json"]
        if !source.apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(source.apiKey)"
        }

        let response = try await uploader.upload(
            request: HTTPUploadRequest(url: url, headers: headers, body: body)
        )
        guard (200..<300).contains(response.statusCode) else {
            let message = String(decoding: response.data, as: UTF8.self)
            throw PostprocessClientError.invalidResponseStatus(response.statusCode, message)
        }

        let content: String?
        switch source.apiProtocol {
        case .chatCompletions:
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: response.data)
            content = decoded.choices.first?.message.content
        case .responses:
            let decoded = try JSONDecoder().decode(ResponsesResponse.self, from: response.data)
            content = decoded.textContent
        }
        guard let content = content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw PostprocessClientError.missingContent
        }
        return content
    }
}

public enum PostprocessPrompt {
    public static let meetingNoteVisionPromptVersion = "1"
    public static let meetingNoteVision = """
    你是会议人工笔记图片识别助手。请读取图片，只提取图片中可以直接观察或识别的文字、数字、表格内容、图示结论和明确标注，不要补充图片外的信息。
    输出简洁中文纯文本，按“图片文字 / 可观察信息 / 不确定内容”组织；没有对应内容时省略该项。无法确认的内容必须标记为“待确认”。
    """
    public static let meetingMinutesPromptVersion = "7"
    public static let meetingMinutesCoverageRuleMarker = "【会议内容组织规则 v5】"
    public static let meetingMinutesOutputRuleMarker = "【正式纪要输出规则 v5】"
    public static let meetingMinutesInputCompatibilityRuleMarker = "【外部转写输入兼容规则 v1】"
    private static let legacyMeetingMinutesCoverageRuleMarker = "【会议主要内容覆盖规则 v2】"
    private static let legacyMeetingMinutesOutputRuleMarker = "【会议纪要结构与篇幅规则 v3】"
    private static let legacyHighFidelityCoverageRuleMarker = "【会议主要内容覆盖规则 v4】"
    private static let legacyHighFidelityOutputRuleMarker = "【会议纪要结构与篇幅规则 v4】"
    public static let meetingMinutesCoverageRules = """
    【会议内容组织规则 v5】
    1. main_topics 按少量核心议题归并。同一事项的背景、事实、观点、分歧、约束、取舍和结果必须放在同一个议题中，不得拆成多项重复表达。
    2. 用户消息给出的数量只是篇幅建议，不是最低数量。通常在建议值上下浮动 1 项；实际议题较少时必须少写，不得拆句、重复或凑数。
    3. 每个议题的 details 用 2 至 4 句概括讨论经过。discussion_steps 只保留 2 至 5 个真正改变讨论方向的关键节点，不逐句复述转写。
    4. viewpoints 只记录能确认发言人或角色、且确有差异的关键意见。无法确认说话人、没有独立依据或与 details 重复时不要生成 viewpoints。
    5. 同一事实不得在 summary、main_topics、key_facts、conclusions、actions 和 risks 中反复展开。各字段各司其职：摘要概览、议题还原、结论定案、行动执行、风险待确认。
    """

    public static let meetingMinutesOutputRules = """
    【正式纪要输出规则 v5】
    1. 输出面向内部流转的正式会议纪要，不是分析报告，也不是转写复述。语言简洁、克制、连贯，避免口语、套话和同义重复。
    2. summary 为一段 120 至 250 字的快速摘要，交代会议目的、核心讨论、已形成结论和下一步，不分条堆砌。
    3. main_topics 保留必要的讨论关系，但不要同时重复输出 details、viewpoints、discussion_steps 和 discussion_process 的相同内容。
    4. conclusions 只放明确形成的结论；actions 只放可执行事项；risks 只放确需确认或处理的问题。空内容使用空数组，不生成“待确认”占位对象。
    5. 原文依据优先使用简短时间范围；只有时间不足以识别事实时才摘录短句。每个议题只保留一处总体依据，不在每个子项后重复证据。
    6. 重要数字、周期和明确事实进入 key_facts；普通背景不重复抄入。不得引入任何会外资料或推断。
    7. 必须一次输出完整 JSON 对象，不要输出推理过程、解释、Markdown 或代码块。
    """

    public static let meetingMinutesInputCompatibilityRules = """
    【外部转写输入兼容规则 v1】
    1. 输入可能来自手机、耳机或第三方转写，可能是连续文本、带时间戳的逐句转写、Markdown 标题/列表、已人工整理稿，或没有说话人和时间的片段。文档表面格式不是质量判断条件，必须完整理解其中可读内容并按本标准输出。
    2. 标题、列表、引用、说话人标记和时间戳都只是原始资料线索。能确认时用于还原议题、人员和证据；无法确认时写“待确认”，不得因为格式不规范而跳过、逐条照抄或生成降级纪要。
    3. 不得把普通句子、列表项或章节标题擅自当作参会人。参会人员只有在原文明确出现姓名、称谓或角色线索时才记录。
    """

    public static let meetingTitle = """
    根据会议转写生成一个简洁、具体的中文会议标题。
    要求：20 个字符以内，概括会议最核心的议题；不要使用“关于”“会议讨论”等空泛开头；不要添加日期、引号、句号或解释。
    只输出标题。
    """

    public static let defaultMouthFillerCleanup = """
    你是会议转写后处理器。请在不改变事实、不新增信息、不删除有效内容的前提下，对整场会议转写做统一清理。

    处理目标：
    1. 删除明显口水词和语气填充词，例如：嗯、啊、呃、额、这个、那个、就是、然后然后、对对对、好好好。
    2. 修复重复断句、明显停顿、无意义重复，但保留正常强调。
    3. 补充必要标点，整理成自然、可阅读的中文会议记录。
    4. 保留原有说话人、时间顺序和发言含义。

    禁止事项：
    1. 不要总结。
    2. 不要提取待办。
    3. 不要改写为书面报告。
    4. 不要合并或改动说话人。
    5. 不要新增原文中没有的信息。

    只输出清理后的文本。
    """

    public static let meetingAnalysis = """
    你是 AgendAI 会小纪内嵌的会议分析 Agent。请基于会议转写和原始会议纪要，结合人员职责、常用词、知识库资料，并按需使用网络搜索工具，生成“AI 分析会议纪要”和结构化待办。

    事实边界：
    1. 原始会议纪要和转写是会议事实；人员库、知识库、网络资料和你的推断不是会议结论，必须明确区分。
    2. 待办负责人优先采用会议明确指定的人；会议未指定时，可按人员职责选择“建议负责人”，assignment_basis 必须写明“职责匹配建议，待确认”及理由；职责匹配程度相近时优先有禅道账号的人员。
    3. owner 只能使用下方启用人员的标准姓名；无法匹配时写“待确认”。有禅道账号的人不能被账号字符串替代，也不能把非人员库成员写成负责人。
    4. deadline 优先使用会议明确期限；若给出建议期限，必须在 assignment_basis 中标为建议并待确认。
    5. 必须生成任务分工派发章节；每条待办必须包含事项、负责人、具体任务、交付物、截止时间和依据。不要把原始会议纪要 actions 直接复制成待办，要结合分析重新梳理。
    6. 使用网络资料时把可核验 URL 写入 sources；不要修改任何本地文件。

    只输出一个合法 JSON 对象，不要 Markdown、代码块或解释。字段必须严格为：
    {
      "title": "AI 分析会议纪要标题",
      "executive_summary": "综合分析摘要，并标明会议事实与外部分析边界",
      "findings": [{"topic":"分析主题","analysis":"分析结论","basis":"会议/人员库/知识库/网络来源或推断"}],
      "todos": [{"id":"todo-1","item":"事项","owner":"标准姓名或待确认","task":"具体要做的事","deliverable":"交付物","deadline":"明确或建议截止时间","assignment_basis":"负责人及期限的分派依据和确认状态","evidence":"会议时间锚点或分析依据"}],
      "risks": ["风险或待确认项"],
      "sources": ["来源名称及 URL；纯会议事实可写会议转写时间锚点"]
    }
    """

    public static let meetingMinutes = """
    你是严谨的中文会议纪要整理助手。请完整阅读会议标题和全部转写，只依据原始内容生成简洁、正式、便于内部流转的结构化会议纪要。

    事实边界：
    1. 不得编造转写中没有的人名、日期、金额、承诺、结论或项目背景。
    2. 区分讨论意见、已形成结论、行动项和风险；不要把建议写成已确认决定。
    3. 负责人或期限不明确时写“待确认”。相对日期可根据用户消息中的当前日期换算；无法可靠换算时写“待确认”。
    4. 结论应保留必要的形成依据，但不要重复议题正文。
    5. 删除口水词和无效重复，合并同一事项的零散讨论，不遗漏重要事实、分歧、决定和后续安排。

    内容完整性：
    1. meeting_title 必须依据整场会议最核心的议题生成，不能直接照抄“新会议”等默认标题。
    2. summary 写成一段完整摘要，概括会议目的、核心讨论、主要结论和后续方向；不能只复述标题，也不能逐条罗列。
    3. main_topics 按少量核心议题归并。details 说明讨论经过、主要观点、约束或分歧及形成方向；discussion_steps 只记录真正影响讨论走向的关键节点。
    4. conclusions 只记录已经形成的决定或共识；actions 只记录需要执行的事项；risks 同时收录明确风险和仍待确认的问题。
    5. 重要数字、周期、案例和项目事实进入 key_facts，并标注其性质；内容长度应随会议实际信息量变化，不能为了简短而丢失重要信息。

    \(meetingMinutesCoverageRules)

    \(meetingMinutesOutputRules)

    \(meetingMinutesInputCompatibilityRules)

    输出要求：
    - 只输出一个 JSON 对象，不要 Markdown、代码块或解释。
    - 所有字段都必须存在；没有明确内容时使用空数组，不要生成空对象。
    - 用户消息可能附带本地专有词和人员称呼映射；所有输出字段必须使用标准名称，不得输出禅道账号或用户 ID。
    - JSON 结构必须严格为：
    {
      "meeting_title": "20个中文字符以内、概括核心议题的会议标题，不含日期和会议纪要字样",
      "meeting_type": "会议类型，如方案研讨、项目汇报、需求澄清；无法确认时写待确认",
      "background_and_purpose": "会议背景与目的；只依据转写，无法确认时说明证据边界",
      "expected_problem": "本次会议预期解决的问题或需要形成的产出；无法确认时写待确认",
      "subtitle": "概括本次会议核心主题的短句",
      "summary": "一段120至250字的正式会议摘要",
      "participants": [{"name": "姓名或会议称谓", "role": "角色线索或待确认", "evidence": "原文依据及时间范围", "status": "待确认"}],
      "main_topics": [{
        "topic": "核心议题",
        "details": "2至4句概括该议题的讨论经过、主要分歧、约束和形成方向",
        "time_range": "议题时间范围",
        "question": "该议题要解决的问题",
        "viewpoints": [{"speaker": "可确认的发言人或角色", "viewpoint": "与其他意见有差异的观点", "basis": "明确依据", "evidence": "简短时间范围"}],
        "discussion_steps": [{"kind": "提问/回应/质疑/取舍/决定", "speaker": "发言人或角色", "content": "改变讨论方向的关键内容", "time_range": "时间范围", "evidence": "必要时的短依据"}],
        "discussion_process": "仅在 details 无法完整表达推进关系时补充",
        "outcome": "形成的方向或未形成结论",
        "status": "已确认/原则同意/暂定方向/未形成结论/待确认",
        "evidence": "议题总体原文依据"
      }],
      "key_facts": [{"item": "事实或数字名称", "value": "值", "nature": "项目事实/示例说明/待核实", "context": "上下文", "evidence": "原文依据"}],
      "conclusions": [{"topic": "事项", "conclusion": "会议结论及必要依据", "status": "状态", "rationale": "形成依据", "scope": "适用范围或前提", "evidence": "原文依据"}],
      "actions": [{"action": "行动项", "owners": ["责任人"], "deadline": "明确日期或待确认", "deliverable": "交付物", "dependencies": ["依赖资料"], "acceptance_criteria": "验收标准", "status": "待确认", "evidence": "原文依据"}],
      "risks": [{"category": "待核实事实/开放问题/假设/分歧/风险", "risk": "风险或待确认事项", "impact": "可能影响", "mitigation": "处理要求", "next_step": "下一步核实或处理", "evidence": "原文依据"}],
      "milestones": [{"date": "时间节点", "target": "目标"}],
      "archive_items": ["需要归档的资料"]
    }
    """

    public static func meetingMinutesWithAdditionalInstructions(
        _ instructions: String,
        basePrompt: String = meetingMinutes
    ) -> String {
        let trimmedBasePrompt = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBasePrompt = trimmedBasePrompt.isEmpty ? meetingMinutes : basePrompt
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return effectiveBasePrompt
        }
        return """
        \(effectiveBasePrompt)

        本次会议的额外整理要求（仅在不违反以上事实边界和输出格式时执行）：
        \(trimmed)
        """
    }

    public static func upgradedMeetingMinutesPrompt(_ prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectivePrompt = normalizedLegacyJSONExample(trimmed.isEmpty ? meetingMinutes : prompt)
        if effectivePrompt.trimmingCharacters(in: .whitespacesAndNewlines) == meetingMinutes.trimmingCharacters(in: .whitespacesAndNewlines) {
            return meetingMinutes
        }
        if looksLikeLegacyBuiltInMeetingMinutesPrompt(effectivePrompt) {
            return meetingMinutes
        }
        var upgraded = removeManagedBlock(effectivePrompt, marker: legacyMeetingMinutesCoverageRuleMarker)
        upgraded = removeManagedBlock(upgraded, marker: legacyMeetingMinutesOutputRuleMarker)
        upgraded = removeManagedBlock(upgraded, marker: legacyHighFidelityCoverageRuleMarker)
        upgraded = removeManagedBlock(upgraded, marker: legacyHighFidelityOutputRuleMarker)
        upgraded = removeManagedBlock(upgraded, marker: meetingMinutesCoverageRuleMarker)
        upgraded = removeManagedBlock(upgraded, marker: meetingMinutesOutputRuleMarker)
        upgraded = removeManagedBlock(upgraded, marker: meetingMinutesInputCompatibilityRuleMarker)
        if !upgraded.contains(meetingMinutesCoverageRuleMarker) {
            upgraded += "\n\n\(meetingMinutesCoverageRules)"
        }
        if !upgraded.contains(meetingMinutesOutputRuleMarker) {
            upgraded += "\n\n\(meetingMinutesOutputRules)"
        }
        if !upgraded.contains(meetingMinutesInputCompatibilityRuleMarker) {
            upgraded += "\n\n\(meetingMinutesInputCompatibilityRules)"
        }
        return upgraded
    }

    private static func looksLikeLegacyBuiltInMeetingMinutesPrompt(_ prompt: String) -> Bool {
        prompt.hasPrefix("你是严谨的中文会议纪要整理助手。请完整阅读会议标题和全部转写，只依据原始内容生成结构化会议纪要。")
            && prompt.contains("main_topics 必须覆盖转写中全部核心议题，每个议题单独一项")
            && prompt.contains(#""main_topics": [{"topic": "核心议题", "details":"#)
            && !prompt.contains(#""meeting_type""#)
    }

    private static func normalizedLegacyJSONExample(_ prompt: String) -> String {
        guard let marker = prompt.range(of: #""summary": “"#),
              let lineEnd = prompt[marker.lowerBound...].firstIndex(of: "\n") else {
            return prompt
        }
        let lineRange = marker.lowerBound..<lineEnd
        let normalizedLine = prompt[lineRange]
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
        return String(prompt[..<lineRange.lowerBound])
            + normalizedLine
            + String(prompt[lineRange.upperBound...])
    }

    private static func removeManagedBlock(_ prompt: String, marker: String) -> String {
        guard let markerRange = prompt.range(of: marker) else { return prompt }
        let suffixStart = markerRange.upperBound
        guard let endRange = prompt.range(of: "\n\n", range: suffixStart..<prompt.endIndex) else {
            return String(prompt[..<markerRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(prompt[..<markerRange.lowerBound]) + String(prompt[endRange.upperBound...])
    }
}

extension PostprocessClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingModel:
            return "模型未选择，请先在模型配置中选择模型。"
        case .visionModelRequired:
            return "当前会议包含图片笔记，但所选模型未声明支持视觉输入。"
        case .invalidBaseURL:
            return "后处理服务地址无效，请检查 baseURL。"
        case .invalidResponseStatus(let statusCode, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "后处理服务返回错误 \(statusCode)。"
            }
            return "后处理服务返回错误 \(statusCode)：\(trimmed)"
        case .missingContent:
            return "后处理服务未返回有效内容。"
        }
    }
}

private struct ChatCompletionRequest: Encodable {
    var model: String
    var messages: [ChatMessage]
    var temperature: Double
    var maxTokens: Int
    var responseFormat: ChatCompletionResponseFormat?
    var chatTemplateKwargs: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
        case chatTemplateKwargs = "chat_template_kwargs"
    }
}

private struct ChatCompletionResponseFormat: Encodable {
    var type: String

    static let jsonObject = ChatCompletionResponseFormat(type: "json_object")
}

private struct ChatMessage: Encodable {
    var role: String
    var content: ChatMessageContent
}

private enum ChatMessageContent: Encodable {
    case text(String)
    case parts([ChatContentPart])

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .text(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .parts(parts):
            var container = encoder.singleValueContainer()
            try container.encode(parts)
        }
    }
}

private struct ChatContentPart: Encodable {
    var type: String
    var text: String?
    var imageURL: ChatImageURL?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    static func text(_ value: String) -> ChatContentPart {
        ChatContentPart(type: "text", text: value, imageURL: nil)
    }

    static func image(mimeType: String, data: Data) -> ChatContentPart {
        ChatContentPart(
            type: "image_url",
            text: nil,
            imageURL: ChatImageURL(
                url: "data:" + mimeType + ";base64," + data.base64EncodedString()
            )
        )
    }
}

private struct ChatImageURL: Encodable {
    var url: String
    var detail = "high"
}

private enum ResponsesInputContent: Encodable {
    case text(String)
    case image(mimeType: String, data: Data)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(value):
            try container.encode("input_text", forKey: .type)
            try container.encode(value, forKey: .text)
        case let .image(mimeType, data):
            try container.encode("input_image", forKey: .type)
            try container.encode(
                "data:" + mimeType + ";base64," + data.base64EncodedString(),
                forKey: .imageURL
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }
}

private struct ChatCompletionResponse: Decodable {
    var choices: [ChatChoice]
}

private struct ChatChoice: Decodable {
    var message: ChatResponseMessage
}

private struct ChatResponseMessage: Decodable {
    var content: String
}

private enum ResponsesInput: Encodable {
    case text(String)
    case parts([ResponsesInputContent])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(value):
            try container.encode(value)
        case let .parts(value):
            try container.encode(value)
        }
    }
}

private struct ResponsesRequest: Encodable {
    var model: String
    var instructions: String
    var input: ResponsesInput
    var maxOutputTokens: Int
    var store: Bool
    var text: ResponsesTextConfiguration?

    enum CodingKeys: String, CodingKey {
        case model, instructions, input, store, text
        case maxOutputTokens = "max_output_tokens"
    }
}

private struct ResponsesTextConfiguration: Encodable {
    var format: ResponsesTextFormat

    static let jsonObject = ResponsesTextConfiguration(
        format: ResponsesTextFormat(type: "json_object")
    )
}

private struct ResponsesTextFormat: Encodable {
    var type: String
}

private struct ResponsesResponse: Decodable {
    var output: [ResponsesOutputItem]
    var outputText: String?

    enum CodingKeys: String, CodingKey {
        case output
        case outputText = "output_text"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        output = try container.decodeIfPresent([ResponsesOutputItem].self, forKey: .output) ?? []
        outputText = try container.decodeIfPresent(String.self, forKey: .outputText)
    }

    var textContent: String? {
        if let outputText, !outputText.isEmpty {
            return outputText
        }
        let text = output
            .flatMap(\.content)
            .compactMap(\.text)
            .joined()
        return text.isEmpty ? nil : text
    }
}

private struct ResponsesOutputItem: Decodable {
    var content: [ResponsesContentItem]

    enum CodingKeys: String, CodingKey {
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try container.decodeIfPresent([ResponsesContentItem].self, forKey: .content) ?? []
    }
}

private struct ResponsesContentItem: Decodable {
    var type: String?
    var text: String?
}
