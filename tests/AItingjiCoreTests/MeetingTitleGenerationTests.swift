import AItingjiCore
import Testing

@Test
func meetingTitleGenerationReplacesOnlyDefaultTitles() {
    #expect(MeetingTitleGeneration.shouldReplace(title: "新会议 16"))
    #expect(MeetingTitleGeneration.shouldReplace(title: "新会议"))
    #expect(!MeetingTitleGeneration.shouldReplace(title: "产品路线评审"))
    #expect(!MeetingTitleGeneration.shouldReplace(title: "新会议复盘"))
}

@Test
func meetingTitleGenerationNormalizesAndLimitsModelOutput() {
    let title = MeetingTitleGeneration.normalize(
        "会议标题：\"广西物联网套餐交付计划与风险评审会议\"。\n这是解释"
    )

    #expect(title == "广西物联网套餐交付计划与风险评审会议")
    #expect((title?.count ?? 0) <= MeetingTitleGeneration.maximumLength)
}

@Test
func meetingTitleGenerationBuildsOrderedBoundedTranscript() {
    let segments = [
        TranscriptSegment(
            id: "second",
            meetingID: "meeting",
            startMs: 2_000,
            endMs: 3_000,
            speakerLabel: "李四",
            rawText: "确认交付时间",
            processedText: "确认交付时间",
            finalText: "确认交付时间"
        ),
        TranscriptSegment(
            id: "first",
            meetingID: "meeting",
            startMs: 0,
            endMs: 1_000,
            speakerLabel: "张三",
            rawText: "讨论产品范围",
            processedText: "讨论产品范围",
            finalText: "讨论产品范围"
        )
    ]

    #expect(
        MeetingTitleGeneration.transcript(from: segments)
            == "张三：讨论产品范围\n李四：确认交付时间"
    )
}
