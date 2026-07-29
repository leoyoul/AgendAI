import AItingjiCore
import Testing

@Test
func timelineContinuationOffsetIsZeroForEmptyMeeting() {
    #expect(RecordingTimelineContinuation.nextOffsetMs(existingSegments: []) == 0)
}

@Test
func timelineContinuationUsesMaxEndMsFromExistingSegments() {
    let segments = [
        TranscriptSegment(id: "s1", meetingID: "m1", startMs: 0, endMs: 5_200, speakerLabel: "张三"),
        TranscriptSegment(id: "s2", meetingID: "m1", startMs: 1_000, endMs: 2_000, speakerLabel: "李四")
    ]

    #expect(RecordingTimelineContinuation.nextOffsetMs(existingSegments: segments) == 5_200)
}

@Test
func timelineContinuationAppliesOffsetToASRSegment() {
    let asr = ASRSegment(startMs: 0, endMs: 1_600, text: "继续录音。")

    let shifted = RecordingTimelineContinuation.apply(offsetMs: 5_200, to: asr)

    #expect(shifted.startMs == 5_200)
    #expect(shifted.endMs == 6_800)
    #expect(shifted.text == "继续录音。")
}
