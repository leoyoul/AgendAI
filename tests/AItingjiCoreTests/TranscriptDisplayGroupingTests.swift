import AItingjiCore
import Testing

@Test
func transcriptDisplayGroupingMergesConsecutiveSegmentsFromSameSpeaker() {
    let segments = [
        TranscriptSegment(id: "s1", meetingID: "m1", startMs: 0, endMs: 1_000, speakerLabel: "张三", rawText: "第一句"),
        TranscriptSegment(id: "s2", meetingID: "m1", startMs: 1_000, endMs: 2_000, speakerLabel: "张三", rawText: "第二句")
    ]

    let groups = TranscriptDisplayGrouper.group(segments)

    #expect(groups.count == 1)
    #expect(groups[0].speakerLabel == "张三")
    #expect(groups[0].startMs == 0)
    #expect(groups[0].endMs == 2_000)
    #expect(groups[0].text == "第一句 第二句")
    #expect(groups[0].segments.map(\.id) == ["s1", "s2"])
}

@Test
func transcriptDisplayGroupingSplitsWhenSpeakerChanges() {
    let segments = [
        TranscriptSegment(id: "s1", meetingID: "m1", startMs: 0, endMs: 1_000, speakerLabel: "张三", rawText: "第一句"),
        TranscriptSegment(id: "s2", meetingID: "m1", startMs: 1_000, endMs: 2_000, speakerLabel: "李四", rawText: "第二句"),
        TranscriptSegment(id: "s3", meetingID: "m1", startMs: 2_000, endMs: 3_000, speakerLabel: "李四", finalText: "第三句")
    ]

    let groups = TranscriptDisplayGrouper.group(segments)

    #expect(groups.count == 2)
    #expect(groups[0].speakerLabel == "张三")
    #expect(groups[0].text == "第一句")
    #expect(groups[1].speakerLabel == "李四")
    #expect(groups[1].startMs == 1_000)
    #expect(groups[1].endMs == 3_000)
    #expect(groups[1].text == "第二句 第三句")
}
