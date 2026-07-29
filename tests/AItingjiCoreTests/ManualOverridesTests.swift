import AItingjiCore
import Testing

private func makeSegment() -> TranscriptSegment {
    TranscriptSegment(
        id: "s1",
        meetingID: "m1",
        startMs: 0,
        endMs: 1000,
        speakerLabel: "未知发言人 1",
        rawText: "我讲一下",
        finalText: "我讲一下"
    )
}

@Test
func manualSpeakerNameHasPriorityOverLaterAutomaticUpdate() {
    let manual = applyManualSpeakerName(
        to: makeSegment(),
        personID: "p1",
        personName: "张三"
    )

    let updated = applyAutomaticSpeakerName(
        to: manual,
        speakerLabel: "未知发言人 2",
        personID: "p2",
        personName: "李四",
        confidence: 0.91
    )

    #expect(updated.speakerLabel == "张三")
    #expect(updated.personID == "p1")
    #expect(updated.personName == "张三")
    #expect(updated.autoSpeakerLabel == "未知发言人 2")
    #expect(updated.isManual)
}

@Test
func manualSpeakerNameBindsSegmentToPerson() {
    let manual = applyManualSpeakerName(
        to: makeSegment(),
        personID: "person-wang",
        personName: "王五"
    )

    #expect(manual.speakerLabel == "王五")
    #expect(manual.personID == "person-wang")
    #expect(manual.personName == "王五")
    #expect(manual.manualReason == ManualOverrideReason.manualRename.rawValue)
}

@Test
func postprocessUpdatesTextWithoutChangingManualSpeaker() {
    let manual = applyManualSpeakerName(
        to: makeSegment(),
        personID: "p1",
        personName: "张三"
    )

    let updated = applyPostprocessText(to: manual, processedText: "我讲一下。")

    #expect(updated.speakerLabel == "张三")
    #expect(updated.personName == "张三")
    #expect(updated.processedText == "我讲一下。")
    #expect(updated.finalText == "我讲一下。")
}
