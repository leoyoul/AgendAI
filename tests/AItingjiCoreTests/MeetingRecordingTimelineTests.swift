import AItingjiCore
import Foundation
import Testing

@Suite("MeetingRecordingTimelineTests")
struct MeetingRecordingTimelineTests {
    @Test
    func beginAndCloseIntervalsKeepMeetingEndOpenUntilStop() {
        var meeting = Meeting(
            id: "timeline",
            title: "时间线",
            createdAt: date(2026, 7, 8, 9)
        )

        MeetingRecordingTimeline.beginInterval(
            for: &meeting,
            at: date(2026, 7, 8, 9)
        )
        MeetingRecordingTimeline.closeInterval(
            for: &meeting,
            at: date(2026, 7, 8, 9, 10)
        )

        #expect(meeting.endedAt == nil)
        #expect(meeting.recordingIntervals.count == 1)
        #expect(meeting.recordingIntervals[0].endedAt == date(2026, 7, 8, 9, 10))
    }

    @Test
    func recoveryBoundsStaleRecordingToAudioEndAndMarksItFailed() {
        let start = date(2026, 7, 11, 19, 37)
        let stale = Meeting(
            id: "stale",
            title: "旧录音",
            status: .recording,
            createdAt: start,
            startedAt: start
        )

        let recovered = MeetingRecordingTimeline.recovered(
            stale,
            endingAt: date(2026, 7, 11, 19, 52)
        )

        #expect(recovered.status == .failed)
        #expect(recovered.endedAt == date(2026, 7, 11, 19, 52))
        #expect(recovered.recordingIntervals.count == 1)
        #expect(recovered.recordingIntervals[0].endedAt == recovered.endedAt)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }
}
