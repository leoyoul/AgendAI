import AItingjiCore
import Testing

@Test
func segmentReplacementPolicyRejectsLargeTextLoss() {
    let original = [
        replacementPolicySegment(id: "s1", startMs: 0, endMs: 10_000, text: "第一段会议内容需要完整保留，不能因为自动处理而丢失。"),
        replacementPolicySegment(id: "s2", startMs: 10_000, endMs: 20_000, text: "第二段会议内容同样需要完整保留，包含关键决策和负责人。")
    ]
    let replacement = [
        replacementPolicySegment(id: "r1", startMs: 0, endMs: 20_000, text: "简短摘要。")
    ]

    let decision = TranscriptSegmentReplacementPolicy.validate(
        replacementSegments: replacement,
        originalSegments: original
    )

    #expect(decision.isAccepted == false)
    #expect(decision.reason?.contains("文本保留不足") == true)
}

@Test
func segmentReplacementPolicyRejectsPoorTimelineCoverage() {
    let original = [
        replacementPolicySegment(id: "s1", startMs: 0, endMs: 20_000, text: "第一段内容"),
        replacementPolicySegment(id: "s2", startMs: 20_000, endMs: 40_000, text: "第二段内容"),
        replacementPolicySegment(id: "s3", startMs: 40_000, endMs: 60_000, text: "第三段内容")
    ]
    let replacement = [
        replacementPolicySegment(id: "r1", startMs: 0, endMs: 5_000, text: "第一段内容第二段内容第三段内容")
    ]

    let decision = TranscriptSegmentReplacementPolicy.validate(
        replacementSegments: replacement,
        originalSegments: original
    )

    #expect(decision.isAccepted == false)
    #expect(decision.reason?.contains("时间覆盖不足") == true)
}

@Test
func segmentReplacementPolicyAcceptsCompleteRetranscriptionWithFewerSegments() {
    let original = [
        replacementPolicySegment(id: "s1", startMs: 0, endMs: 10_000, text: "我们先确认项目目标。"),
        replacementPolicySegment(id: "s2", startMs: 10_000, endMs: 20_000, text: "再讨论交付风险。"),
        replacementPolicySegment(id: "s3", startMs: 20_000, endMs: 30_000, text: "最后确认负责人。")
    ]
    let replacement = [
        replacementPolicySegment(id: "r1", startMs: 0, endMs: 30_000, text: "我们先确认项目目标，再讨论交付风险，最后确认负责人。")
    ]

    let decision = TranscriptSegmentReplacementPolicy.validate(
        replacementSegments: replacement,
        originalSegments: original
    )

    #expect(decision.isAccepted)
}

private func replacementPolicySegment(id: String, startMs: Int, endMs: Int, text: String) -> TranscriptSegment {
    TranscriptSegment(
        id: id,
        meetingID: "meeting-replacement-policy",
        startMs: startMs,
        endMs: endMs,
        speakerLabel: "临时发言人",
        rawText: text,
        processedText: text,
        finalText: text
    )
}
