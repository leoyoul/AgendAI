import Testing
@testable import AItingjiCore

@Test
func meetingMinutesPromptKeepsBuiltInRulesAndAddsOptionalInstructions() {
    #expect(PostprocessPrompt.meetingMinutesWithAdditionalInstructions("   ") == PostprocessPrompt.meetingMinutes)
    #expect(PostprocessPrompt.meetingMinutes.contains("summary 写成一段完整摘要"))
    #expect(PostprocessPrompt.meetingMinutes.contains("\"main_topics\""))
    #expect(PostprocessPrompt.meetingMinutes.contains(PostprocessPrompt.meetingMinutesCoverageRuleMarker))
    #expect(PostprocessPrompt.meetingMinutes.contains(PostprocessPrompt.meetingMinutesOutputRuleMarker))
    #expect(!PostprocessPrompt.meetingMinutes.contains("宁可提取更多具体要点"))

    let prompt = PostprocessPrompt.meetingMinutesWithAdditionalInstructions(
        "重点提取明确的行动项和风险。"
    )
    #expect(prompt.contains("你是严谨的中文会议纪要整理助手"))
    #expect(prompt.contains("本次会议的额外整理要求"))
    #expect(prompt.contains("重点提取明确的行动项和风险。"))

    let customPrompt = PostprocessPrompt.meetingMinutesWithAdditionalInstructions(
        "保留技术细节。",
        basePrompt: "自定义会议纪要规则"
    )
    #expect(customPrompt.hasPrefix("自定义会议纪要规则"))
    #expect(customPrompt.contains("保留技术细节。"))
    #expect(!customPrompt.contains("你是严谨的中文会议纪要整理助手"))
}

@Test
func meetingMinutesPromptUpgradePreservesCustomContentAndIsIdempotent() {
    let customPrompt = "自定义摘要规则"
    let upgraded = PostprocessPrompt.upgradedMeetingMinutesPrompt(customPrompt)

    #expect(upgraded.hasPrefix(customPrompt))
    #expect(upgraded.contains(PostprocessPrompt.meetingMinutesCoverageRuleMarker))
    #expect(upgraded.contains(PostprocessPrompt.meetingMinutesOutputRuleMarker))
    #expect(PostprocessPrompt.upgradedMeetingMinutesPrompt(upgraded) == upgraded)
}

@Test
func meetingMinutesPromptUpgradeRepairsLegacyCurlyQuotes() {
    let legacy = """
    保留旧版规则。
    {
      "summary": “3-6句话用足够概括的语言完全总结出会议的背景、目标和结论“,
      "actions": []
    }
    """

    let upgraded = PostprocessPrompt.upgradedMeetingMinutesPrompt(legacy)

    #expect(PostprocessPrompt.meetingMinutesPromptVersion == "7")
    #expect(upgraded.contains(#""summary": "3-6句话用足够概括的语言完全总结出会议的背景、目标和结论","#))
    #expect(!upgraded.contains(#""summary": “"#))
    #expect(PostprocessPrompt.upgradedMeetingMinutesPrompt(upgraded) == upgraded)
}

@Test
func legacyBuiltInMinutesPromptMigratesToCompactFormalPrompt() {
    let legacy = """
    你是严谨的中文会议纪要整理助手。请完整阅读会议标题和全部转写，只依据原始内容生成结构化会议纪要。
    main_topics 必须覆盖转写中全部核心议题，每个议题单独一项。
    {
      "main_topics": [{"topic": "核心议题", "details": "详细说明"}]
    }

    【会议主要内容覆盖规则 v4】
    宁可提取更多具体要点。
    """

    let upgraded = PostprocessPrompt.upgradedMeetingMinutesPrompt(legacy)

    #expect(upgraded == PostprocessPrompt.meetingMinutes)
    #expect(upgraded.contains("按少量核心议题归并"))
    #expect(upgraded.contains("内部流转的正式会议纪要"))
}
