import AItingjiCore
import SwiftUI

struct WeekCalendarView: View {
    let meetings: [Meeting]
    let activeMeetingID: Meeting.ID?
    @Binding var displayedWeekDate: Date
    let onSelectMeeting: (Meeting.ID) -> Void

    private let hourHeight: CGFloat = 64
    private let minimumDisplayMinutes = 42

    var body: some View {
        if hasActiveMeeting {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                calendarContent(now: context.date)
            }
        } else {
            calendarContent(now: Date())
        }
    }

    private var hasActiveMeeting: Bool {
        activeMeetingID != nil
    }

    private func calendarContent(now: Date) -> some View {
        let calendar = Calendar.current
        let week = MeetingCalendar.week(
            containing: displayedWeekDate,
            meetings: meetings,
            now: now,
            calendar: calendar,
            activeMeetingID: activeMeetingID
        )
        let layoutItems = MeetingCalendar.layoutItems(
            for: week.scheduledMeetings,
            in: week.interval,
            now: now,
            calendar: calendar,
            minimumDisplayMinutes: minimumDisplayMinutes,
            activeMeetingID: activeMeetingID
        )

        return VStack(spacing: 0) {
            WeekCalendarToolbar(
                displayedWeekDate: $displayedWeekDate,
                weekInterval: week.interval,
                calendar: calendar
            )

            if !week.unscheduled.isEmpty {
                UnscheduledMeetingsView(
                    meetings: week.unscheduled,
                    onSelectMeeting: onSelectMeeting
                )
                Divider()
            }

            WeekTimelineGrid(
                weekInterval: week.interval,
                meetings: week.scheduledMeetings,
                layoutItems: layoutItems,
                now: now,
                hourHeight: hourHeight,
                onSelectMeeting: onSelectMeeting
            )
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
