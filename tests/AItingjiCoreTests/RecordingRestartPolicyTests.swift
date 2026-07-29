import AItingjiCore
import Testing

@Test
func recordingRestartPolicyAllowsEmptyDraftMeeting() {
    let meeting = Meeting(id: "m1", title: "新会议", status: .draft, createdAt: .init())

    let decision = RecordingRestartPolicy.validate(meeting: meeting, existingSegmentCount: 0)

    #expect(decision.isAccepted)
}

@Test
func recordingRestartPolicyRejectsRestartWhenExistingTranscriptWouldBeKeptWithNewAudio() {
    let meeting = Meeting(
        id: "m1",
        title: "旧会议",
        status: .done,
        createdAt: .init(),
        audioFilePath: "/tmp/old.wav"
    )

    let decision = RecordingRestartPolicy.validate(meeting: meeting, existingSegmentCount: 9)

    #expect(!decision.isAccepted)
    #expect(decision.reason == "当前会议已有 9 条转写记录。请新建会议后再录音，避免新录音覆盖旧音频导致说话人校正错位。")
}
