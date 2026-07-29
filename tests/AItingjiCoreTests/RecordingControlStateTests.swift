import AItingjiCore
import Testing

@Test
func recordingControlStateKeepsStopEnabledWhilePaused() {
    let state = RecordingControlPresentation(state: .paused)

    #expect(state.primaryActionTitle == "继续")
    #expect(state.canStartOrResume)
    #expect(!state.canPause)
    #expect(state.canStop)
    #expect(state.statusText == "已暂停")
}

@Test
func recordingControlStateDisablesStartWhileStarting() {
    let state = RecordingControlPresentation(state: .starting)

    #expect(!state.canStartOrResume)
    #expect(!state.canPause)
    #expect(!state.canStop)
    #expect(state.statusText == "启动中")
}

@Test
func recordingControlStateAllowsPauseAndStopOnlyWhenRecording() {
    let state = RecordingControlPresentation(state: .recording)

    #expect(!state.canStartOrResume)
    #expect(state.canPause)
    #expect(state.canStop)
    #expect(state.statusText == "录音中")
}

@Test
func recordingElapsedTimeUsesStableHoursMinutesSecondsFormat() {
    #expect(RecordingControlPresentation.formattedElapsedTime(milliseconds: -1) == "00:00:00")
    #expect(RecordingControlPresentation.formattedElapsedTime(milliseconds: 999) == "00:00:00")
    #expect(RecordingControlPresentation.formattedElapsedTime(milliseconds: 61_000) == "00:01:01")
    #expect(RecordingControlPresentation.formattedElapsedTime(milliseconds: 3_661_999) == "01:01:01")
}
