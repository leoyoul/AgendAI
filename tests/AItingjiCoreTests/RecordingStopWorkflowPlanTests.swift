import AItingjiCore
import Testing

@Suite("Recording stop workflow plan")
struct RecordingStopWorkflowPlanTests {
    @Test("automatic workflow consumes only realtime transcript")
    func automaticWorkflow() {
        #expect(
            RecordingStopWorkflowPlan.automatic.steps == [
                .drainPendingRealtimeTranscription,
                .finishAudioCapture,
                .generateMeetingMinutes,
                .updateMeetingTitle
            ]
        )
    }

    @Test("automatic workflow excludes expensive legacy processing")
    func excludesLegacyProcessing() {
        let steps = RecordingStopWorkflowPlan.automatic.steps

        #expect(!steps.contains(.retranscribeFullRecording))
        #expect(!steps.contains(.separateSpeakers))
        #expect(!steps.contains(.polishRealtimeTranscript))
    }
}
