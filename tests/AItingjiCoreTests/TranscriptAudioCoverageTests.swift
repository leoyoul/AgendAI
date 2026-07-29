import AItingjiCore
import Testing

@Test
func transcriptAudioCoverageAcceptsAlignedAudioAndSegments() {
    let segments = [
        TranscriptSegment(id: "s1", meetingID: "m1", startMs: 0, endMs: 5_000, speakerLabel: "A"),
        TranscriptSegment(id: "s2", meetingID: "m1", startMs: 6_000, endMs: 40_000, speakerLabel: "B")
    ]

    let decision = TranscriptAudioCoverage.validate(audioDurationMs: 46_000, segments: segments)

    #expect(decision.isAccepted)
}

@Test
func transcriptAudioCoverageRejectsAudioThatCannotCoverTranscriptTimeline() {
    let segments = [
        TranscriptSegment(id: "s1", meetingID: "m1", startMs: 0, endMs: 5_200, speakerLabel: "张三"),
        TranscriptSegment(id: "s2", meetingID: "m1", startMs: 648_400, endMs: 704_380, speakerLabel: "临时发言人")
    ]

    let decision = TranscriptAudioCoverage.validate(audioDurationMs: 46_000, segments: segments)

    #expect(!decision.isAccepted)
    #expect(decision.reason == "录音时长 46.0 秒，短于当前转写时间轴 704.4 秒，已保留原记录。")
}

@Test
func transcriptAudioCoverageSuggestsOffsetWhenExistingPrefixSegmentsExplainTimelineGap() {
    let segments = [
        TranscriptSegment(id: "s1", meetingID: "m1", startMs: 0, endMs: 5_200, speakerLabel: "张三"),
        TranscriptSegment(id: "s2", meetingID: "m1", startMs: 6_200, endMs: 11_800, speakerLabel: "未知发言人 1"),
        TranscriptSegment(id: "s3", meetingID: "m1", startMs: 13_000, endMs: 18_400, speakerLabel: "李四"),
        TranscriptSegment(id: "s4", meetingID: "m1", startMs: 18_400, endMs: 28_400, speakerLabel: "临时发言人"),
        TranscriptSegment(id: "s5", meetingID: "m1", startMs: 315_744, endMs: 325_744, speakerLabel: "临时发言人")
    ]

    let decision = TranscriptAudioCoverage.validate(audioDurationMs: 307_344, segments: segments)

    #expect(decision.isAccepted)
    #expect(decision.timelineOffsetMs == 18_400)
}
