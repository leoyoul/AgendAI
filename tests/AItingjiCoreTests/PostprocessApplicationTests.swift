import AItingjiCore
import Testing

@Test
func postprocessApplicationUpdatesTextWithoutChangingSpeakerFields() {
    let segment = TranscriptSegment(
        id: "segment-1",
        meetingID: "meeting-1",
        startMs: 0,
        endMs: 3000,
        speakerLabel: "张三",
        autoSpeakerLabel: "张三",
        personID: "person-zhang",
        personName: "张三",
        confidence: 0.92,
        rawText: "我们开始讨论产品路线和风险",
        processedText: "我们开始讨论产品路线和风险",
        finalText: "我们开始讨论产品路线和风险"
    )

    let updated = PostprocessApplication.apply(polishedText: "我们开始讨论产品路线和风险。", to: segment)

    #expect(updated.speakerLabel == "张三")
    #expect(updated.autoSpeakerLabel == "张三")
    #expect(updated.personID == "person-zhang")
    #expect(updated.personName == "张三")
    #expect(updated.confidence == 0.92)
    #expect(updated.rawText == "我们开始讨论产品路线和风险")
    #expect(updated.processedText == "我们开始讨论产品路线和风险。")
    #expect(updated.finalText == "我们开始讨论产品路线和风险。")
}

@Test
func postprocessApplicationKeepsOriginalTextWhenOutputIsEmpty() {
    let segment = makePostprocessSegment(text: "今天我们讨论产品路线和下个版本的风险。")

    let updated = PostprocessApplication.apply(polishedText: "   ", to: segment)

    #expect(updated.finalText == segment.finalText)
    #expect(updated.processedText == segment.processedText)
}

@Test
func postprocessApplicationKeepsOriginalTextWhenOutputIsTooShort() {
    let segment = makePostprocessSegment(text: "今天我们讨论产品路线和下个版本的风险，需要明确负责人和验收标准。")

    let updated = PostprocessApplication.apply(polishedText: "讨论路线。", to: segment)

    #expect(updated.finalText == segment.finalText)
    #expect(updated.processedText == segment.processedText)
}

@Test
func postprocessApplicationKeepsOriginalTextWhenOutputLosesMostContent() {
    let segment = makePostprocessSegment(text: "今天我们讨论产品路线和下个版本的风险，需要明确负责人和验收标准。")

    let updated = PostprocessApplication.apply(polishedText: "今天讨论产品路线。", to: segment)

    #expect(updated.finalText == segment.finalText)
    #expect(updated.processedText == segment.processedText)
}

@Test
func postprocessApplicationUsesRawTextWhenFinalTextWasPreviouslyPolluted() {
    let segment = TranscriptSegment(
        id: "segment-polluted",
        meetingID: "meeting-postprocess",
        startMs: 0,
        endMs: 3000,
        speakerLabel: "张三",
        autoSpeakerLabel: "张三",
        confidence: 0.9,
        rawText: "今天我们讨论产品路线和下个版本的风险，需要明确负责人和验收标准。",
        processedText: "总结。",
        finalText: "总结。"
    )

    #expect(PostprocessApplication.sourceText(for: segment) == "今天我们讨论产品路线和下个版本的风险，需要明确负责人和验收标准。")
    let updated = PostprocessApplication.apply(polishedText: "今天我们讨论产品路线和下个版本的风险，需要明确负责人和验收标准。", to: segment)
    #expect(updated.finalText == "今天我们讨论产品路线和下个版本的风险，需要明确负责人和验收标准。")
}

@Test
func postprocessApplicationPreservesManualFinalTextAsSource() {
    var segment = makePostprocessSegment(text: "原始转写")
    segment.finalText = "人工修正后的完整文本"
    segment.isManual = true

    #expect(PostprocessApplication.sourceText(for: segment) == "人工修正后的完整文本")
}

@Test
func postprocessApplicationAllowsShortSourceTextCleanup() {
    let segment = makePostprocessSegment(text: "好")

    let updated = PostprocessApplication.apply(polishedText: "好。", to: segment)

    #expect(updated.finalText == "好。")
}

private func makePostprocessSegment(text: String) -> TranscriptSegment {
    TranscriptSegment(
        id: "segment-postprocess",
        meetingID: "meeting-postprocess",
        startMs: 0,
        endMs: 3000,
        speakerLabel: "张三",
        autoSpeakerLabel: "张三",
        confidence: 0.9,
        rawText: text,
        processedText: text,
        finalText: text
    )
}
