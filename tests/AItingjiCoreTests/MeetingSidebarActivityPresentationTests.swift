import AItingjiCore
import Testing

@Suite("Meeting sidebar activity presentation")
struct MeetingSidebarActivityPresentationTests {
    @Test("recording has the highest priority")
    func recordingWins() {
        let presentation = MeetingSidebarActivityPresentation(
            isRecording: true,
            isPostprocessing: true,
            isRecentlyCompleted: true
        )

        #expect(presentation == .recording)
    }

    @Test("postprocessing precedes recent completion")
    func postprocessingWins() {
        let presentation = MeetingSidebarActivityPresentation(
            isRecording: false,
            isPostprocessing: true,
            isRecentlyCompleted: true
        )

        #expect(presentation == .postprocessing)
    }

    @Test("recent completion is shown when no work is active")
    func recentlyCompleted() {
        let presentation = MeetingSidebarActivityPresentation(
            isRecording: false,
            isPostprocessing: false,
            isRecentlyCompleted: true
        )

        #expect(presentation == .recentlyCompleted)
    }

    @Test("inactive meetings have no activity")
    func inactive() {
        let presentation = MeetingSidebarActivityPresentation(
            isRecording: false,
            isPostprocessing: false,
            isRecentlyCompleted: false
        )

        #expect(presentation == .none)
    }
}
