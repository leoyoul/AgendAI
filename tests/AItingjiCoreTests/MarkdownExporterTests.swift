import AItingjiCore
import Foundation
import Testing

@Test
func markdownExportIncludesNamesUnknownLabelsTimelineAndManualMarker() {
    let meeting = Meeting(
        id: "m1",
        title: "周会",
        captureSource: .microphone,
        createdAt: Date(timeIntervalSince1970: 0)
    )
    let segments = [
        TranscriptSegment(
            id: "s1",
            meetingID: "m1",
            startMs: 0,
            endMs: 1000,
            speakerLabel: "未知发言人 1",
            rawText: "先汇报一下进展",
            finalText: "先汇报一下进展"
        ),
        TranscriptSegment(
            id: "s2",
            meetingID: "m1",
            startMs: 1000,
            endMs: 2000,
            speakerLabel: "speaker_2",
            personID: "p1",
            personName: "张三",
            rawText: "我补充一点",
            finalText: "我补充一点。",
            isManual: true,
            manualReason: "manual_rename"
        )
    ]

    let markdown = MarkdownExporter().export(meeting: meeting, segments: segments)

    #expect(markdown.contains("# 周会"))
    #expect(markdown.contains("未知发言人 1"))
    #expect(markdown.contains("张三"))
    #expect(markdown.contains("[00:01-00:02]"))
    #expect(markdown.contains("人工修正"))
    #expect(markdown.contains("我补充一点。"))
}

@Test
func markdownExportOmitsUnassignedSpeakerPlaceholder() {
    let meeting = Meeting(
        id: "m1",
        title: "周会",
        captureSource: .microphone,
        createdAt: Date(timeIntervalSince1970: 0)
    )
    let segment = TranscriptSegment(
        id: "s1",
        meetingID: "m1",
        startMs: 0,
        endMs: 1000,
        speakerLabel: "未分配发言人",
        rawText: "直接使用实时转写。"
    )

    let markdown = MarkdownExporter().export(meeting: meeting, segments: [segment])

    #expect(markdown.contains("[00:00-00:01] 直接使用实时转写。"))
    #expect(!markdown.contains("未分配发言人"))
}
